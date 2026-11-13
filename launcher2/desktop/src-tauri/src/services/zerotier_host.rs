//! On the host's PC, which runs Coco's ZeroTier controller, friends who join the network are
//! accepted automatically while Coco is open (what Coco 1's authorizer did). On any other PC
//! the controller does not answer for this network and the loop just waits quietly. With the
//! host offline nothing breaks: a friend's join stays pending and is accepted the next time
//! the host opens Coco, because ZeroTier keeps retrying on its own.
use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Duration;

const NETWORK_ID:&str="58997fc5f3c0c001";
const API:&str="http://127.0.0.1:9993/controller/network";
const POLL:Duration=Duration::from_secs(3);
const NOT_HOST_RETRY:Duration=Duration::from_secs(120);

fn token()->Option<String>{
    let mut candidates=Vec::new();
    if let Some(local)=std::env::var_os("LOCALAPPDATA"){candidates.push(PathBuf::from(local).join("ZeroTier").join("authtoken.secret"));}
    candidates.push(PathBuf::from("C:\\ProgramData\\ZeroTier\\One\\authtoken.secret"));
    candidates.iter().find_map(|path|std::fs::read_to_string(path).ok()).map(|text|text.trim().to_string()).filter(|text|!text.is_empty())
}

/// Whether this PC has joined Coco's network, asked to ZeroTier itself on its local API, so it
/// does not depend on where the installer put its executables. None when it cannot tell (no
/// readable token yet, or the service is not answering).
pub(crate) fn local_membership()->Option<(bool,String)>{
    let token=token()?;
    let client=reqwest::blocking::Client::builder().timeout(Duration::from_secs(4)).no_proxy().build().ok()?;
    let response=client.get(format!("http://127.0.0.1:9993/network/{NETWORK_ID}")).header("X-ZT1-Auth",&token).send().ok()?;
    match response.status().as_u16(){
        200=>{
            let network:Value=serde_json::from_str(&response.text().ok()?).ok()?;
            let status=network.get("status").and_then(Value::as_str).unwrap_or("?").to_string();
            let address=network.get("assignedAddresses").and_then(Value::as_array).and_then(|list|list.first())
                .and_then(Value::as_str).unwrap_or("-").to_string();
            Some((true,format!("{status} · {address}")))
        }
        404=>Some((false,"no unida".into())),
        _=>None,
    }
}

/// Members that are not yet authorized, given the controller's member list and a lookup of
/// each member's record. Kept pure so the decision is testable without a controller.
pub(crate) fn pending_members(list:&Value,mut record:impl FnMut(&str)->Option<Value>)->Vec<String>{
    let Some(members)=list.as_object() else {return Vec::new()};
    members.keys().filter(|node|node.len()==10&&node.bytes().all(|b|b.is_ascii_hexdigit()))
        .filter(|node|record(node).is_some_and(|member|member.get("authorized").and_then(Value::as_bool)==Some(false)))
        .cloned().collect()
}

fn run(){
    let Ok(client)=reqwest::blocking::Client::builder().timeout(Duration::from_secs(8)).no_proxy().build() else {return};
    // Revisions already seen authorized: only new or changed members are looked up again.
    let mut known:HashMap<String,u64>=HashMap::new();
    let mut announced=false;
    loop{
        let Some(token)=token() else {std::thread::sleep(NOT_HOST_RETRY);continue};
        let get=|url:String|client.get(url).header("X-ZT1-Auth",&token).send().ok()
            .filter(|response|response.status().is_success()).and_then(|response|response.text().ok()).and_then(|text|serde_json::from_str::<Value>(&text).ok());
        let Some(list)=get(format!("{API}/{NETWORK_ID}/member")) else {std::thread::sleep(NOT_HOST_RETRY);continue};
        if !announced{crate::services::diagnostics::log("zerotier","este PC es el anfitrión: aceptando amigos automáticamente");announced=true;}
        let changed:Vec<String>=list.as_object().map(|members|members.iter()
            .filter(|(node,revision)|known.get(*node)!=revision.as_u64().as_ref()).map(|(node,_)|node.clone()).collect()).unwrap_or_default();
        let subset:serde_json::Map<String,Value>=changed.iter().filter_map(|node|list.get(node).map(|value|(node.clone(),value.clone()))).collect();
        let mut records:HashMap<String,Value>=HashMap::new();
        let pending=pending_members(&Value::Object(subset),|node|{
            let member=get(format!("{API}/{NETWORK_ID}/member/{node}"))?;
            records.insert(node.to_string(),member.clone());
            Some(member)
        });
        let mut accepted=0;
        for node in &pending{
            let ok=client.post(format!("{API}/{NETWORK_ID}/member/{node}")).header("X-ZT1-Auth",&token)
                .header("Content-Type","application/json").body(r#"{"authorized":true}"#).send()
                .ok().and_then(|response|response.text().ok()).and_then(|text|serde_json::from_str::<Value>(&text).ok())
                .is_some_and(|member|member.get("authorized").and_then(Value::as_bool)==Some(true));
            if ok{accepted+=1;crate::services::diagnostics::log("zerotier",&format!("amigo aceptado en la red: {node}"));}
            else{crate::services::diagnostics::log("zerotier",&format!("no se pudo aceptar {node}"));}
        }
        if accepted>0{
            // A first join may have been refused milliseconds earlier; republishing the network
            // makes the controller send the new member its config now, not on ZeroTier's slow retry.
            if let Some(network)=get(format!("{API}/{NETWORK_ID}")){
                let _=client.post(format!("{API}/{NETWORK_ID}")).header("X-ZT1-Auth",&token)
                    .header("Content-Type","application/json").body(network.to_string()).send();
            }
        }
        for (node,member) in records{
            if member.get("authorized").and_then(Value::as_bool)==Some(true)||pending.contains(&node){
                if let Some(revision)=list.get(&node).and_then(Value::as_u64){known.insert(node,revision);}
            }
        }
        std::thread::sleep(POLL);
    }
}

pub fn accept_friends_in_background(){
    std::thread::spawn(run);
}

#[cfg(test)]
mod tests{
    use super::*;
    use serde_json::json;

    #[test]
    fn only_real_unauthorized_members_are_accepted(){
        let list=json!({"aaaaaaaaaa":3,"bbbbbbbbbb":1,"cccccccccc":2,"not-a-node":1,"dddddddddd":5});
        let records=json!({
            "aaaaaaaaaa":{"authorized":false},"bbbbbbbbbb":{"authorized":true},
            "cccccccccc":{"authorized":false},"not-a-node":{"authorized":false}});
        let mut pending=pending_members(&list,|node|records.get(node).cloned());
        pending.sort();
        assert_eq!(pending,vec!["aaaaaaaaaa","cccccccccc"],"unknown records and malformed ids are skipped");
        assert!(pending_members(&json!([]),|_|None).is_empty());
    }
}
