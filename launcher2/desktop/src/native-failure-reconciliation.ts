/** Read-only, partial-success snapshot after a failed native write. These
 * callbacks must only inspect journals and current state, NEVER replay them. */
export async function inspectAfterNativeFailure<TPending,TInstances,TRepair,TPlan=never>(
  readPending:()=>Promise<TPending>,readInstances:()=>Promise<TInstances>,
  readRepair?:()=>Promise<TRepair>,
  readPlan?:()=>Promise<TPlan>,
):Promise<{pending:TPending|null;instances:TInstances|null;repair:TRepair|null;plan:TPlan|null;unavailable:string[]}>{
  const [pending,instances,repair,plan]=await Promise.allSettled([
    Promise.resolve().then(readPending),
    Promise.resolve().then(readInstances),
    readRepair?Promise.resolve().then(readRepair):Promise.resolve(null),
    readPlan?Promise.resolve().then(readPlan):Promise.resolve(null),
  ]);
  const unavailable:string[]=[];
  if(pending.status==='rejected')unavailable.push('journals');
  if(instances.status==='rejected')unavailable.push('instances');
  if(readRepair&&repair.status==='rejected')unavailable.push('repair');
  if(readPlan&&plan.status==='rejected')unavailable.push('plan');
  return {
    pending:pending.status==='fulfilled'?pending.value:null,
    instances:instances.status==='fulfilled'?instances.value:null,
    repair:repair.status==='fulfilled'?repair.value:null,
    plan:plan.status==='fulfilled'?plan.value:null,
    unavailable,
  };
}
