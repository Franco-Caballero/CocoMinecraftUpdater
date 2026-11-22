//! On the host's PC, which runs Coco's ZeroTier controller, friends who join the network are
//! accepted automatically while Coco is open (what Coco 1's authorizer did). On any other PC
//! the controller does not answer for this network and the loop just waits quietly. With the
//! host offline nothing breaks: a friend's join stays pending and is accepted the next time
//! the host opens Coco, because ZeroTier keeps retrying on its own.
use serde_json::Value;
use std::collections::HashMap;
use std::io::Read;
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
        if !announced{
            crate::services::diagnostics::log("zerotier","este PC es el anfitrión: aceptando amigos automáticamente");
            announced=true;
            let token=token.clone();
            std::thread::spawn(move||receive_names(token));
        }
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

/// Whether this PC runs the controller of Coco's network (the host's PC).
pub(crate) fn is_host()->bool{
    let Some(token)=token() else {return false};
    reqwest::blocking::Client::builder().timeout(Duration::from_secs(4)).no_proxy().build().ok()
        .and_then(|client|client.get(format!("{API}/{NETWORK_ID}")).header("X-ZT1-Auth",&token).send().ok())
        .is_some_and(|response|response.status().is_success())
}

pub fn accept_friends_in_background(){
    std::thread::spawn(run);
    std::thread::spawn(announce_name);
}

// ---------------------------------------------------------------------------------------------
// Player names on the network. Each Coco tells the host's Coco its profile name over the Coco
// network; the host checks that the sender's address belongs to a member and stores the name on
// that member in its ZeroTier controller, so every 10.77.37.x has a name. Names are labels only:
// nothing is authorized or trusted because of them.

const HOST_IP:&str="10.77.37.1";
const NAME_PORT:u16=37737;
const NAME_MAGIC:&str="COCO-NAME 1 ";
const ANNOUNCE_EVERY:Duration=Duration::from_secs(60);
/// Sent again now and then, in case the host's controller lost it.
const ANNOUNCE_REFRESH:Duration=Duration::from_secs(30*60);

/// The profile name rules (3–16 ASCII letters, digits or _), so nothing else reaches the controller.
pub(crate) fn parse_name_request(line:&str)->Option<String>{
    let name=line.trim_end_matches(['\r','\n']).strip_prefix(NAME_MAGIC)?;
    crate::services::identity::valid_minecraft_username(name).then(||name.to_string())
}

/// The member whose managed address is exactly `ip`.
pub(crate) fn member_with_address<'a>(records:impl IntoIterator<Item=(&'a str,&'a Value)>,ip:&str)->Option<String>{
    records.into_iter().find(|(_,member)|member.get("ipAssignments").and_then(Value::as_array)
        .is_some_and(|list|list.iter().any(|address|address.as_str()==Some(ip))))
        .map(|(node,_)|node.to_string())
}

fn is_coco_client_address(ip:&std::net::Ipv4Addr)->bool{
    let octets=ip.octets();
    octets[..3]==[10,77,37]&&(1..=254).contains(&octets[3])
}

/// This PC's address on the Coco network, from ZeroTier's own API.
fn local_coco_address(client:&reqwest::blocking::Client,token:&str)->Option<std::net::Ipv4Addr>{
    let text=client.get(format!("http://127.0.0.1:9993/network/{NETWORK_ID}")).header("X-ZT1-Auth",token).send().ok()
        .filter(|response|response.status().is_success())?.text().ok()?;
    let network:Value=serde_json::from_str(&text).ok()?;
    network.get("assignedAddresses")?.as_array()?.iter().filter_map(Value::as_str)
        .filter_map(|cidr|cidr.split('/').next()?.parse::<std::net::Ipv4Addr>().ok())
        .find(is_coco_client_address)
}

fn profile_name()->Option<String>{
    let local=std::env::var_os("LOCALAPPDATA")?;
    let path=crate::services::identity::identity_path_from_local_app_data(std::path::Path::new(&local));
    crate::services::identity::get_local_identity_at_path(&path).ok()?.username
}

fn send_name(name:&str)->bool{
    use std::io::{BufRead,BufReader,Write};
    let Ok(address)=format!("{HOST_IP}:{NAME_PORT}").parse::<std::net::SocketAddr>() else {return false};
    let Ok(mut stream)=std::net::TcpStream::connect_timeout(&address,Duration::from_secs(4)) else {return false};
    let _=stream.set_read_timeout(Some(Duration::from_secs(10)));
    if stream.write_all(format!("{NAME_MAGIC}{name}\n").as_bytes()).is_err(){return false;}
    let mut reply=String::new();
    BufReader::new(stream.take(64)).read_line(&mut reply).is_ok()&&reply.trim()=="OK"
}

/// Every PC, the host included: send the profile name whenever it or the address changes.
fn announce_name(){
    let Ok(client)=reqwest::blocking::Client::builder().timeout(Duration::from_secs(4)).no_proxy().build() else {return};
    let mut sent:Option<(String,std::net::Ipv4Addr,std::time::Instant)>=None;
    loop{
        if let (Some(token),Some(name))=(token(),profile_name()){
            if let Some(address)=local_coco_address(&client,&token){
                let fresh=sent.as_ref().is_some_and(|(last,at,when)|*last==name&&*at==address&&when.elapsed()<ANNOUNCE_REFRESH);
                if !fresh&&send_name(&name){sent=Some((name,address,std::time::Instant::now()));}
            }
        }
        std::thread::sleep(ANNOUNCE_EVERY);
    }
}

/// Host only: listen on the host address of the Coco network (never on the home network).
fn receive_names(token:String){
    use std::io::{BufRead,BufReader,Write};
    let Ok(client)=reqwest::blocking::Client::builder().timeout(Duration::from_secs(8)).no_proxy().build() else {return};
    let listener=loop{
        match std::net::TcpListener::bind((HOST_IP,NAME_PORT)){
            Ok(listener)=>break listener,
            // The adapter may come up after Coco: try again later.
            Err(_)=>std::thread::sleep(NOT_HOST_RETRY),
        }
    };
    crate::services::diagnostics::log("zerotier","recibiendo los nombres de perfil de los amigos");
    let get=|url:String|client.get(url).header("X-ZT1-Auth",&token).send().ok()
        .filter(|response|response.status().is_success()).and_then(|response|response.text().ok()).and_then(|text|serde_json::from_str::<Value>(&text).ok());
    for stream in listener.incoming(){
        let Ok(mut stream)=stream else {continue};
        let Ok(std::net::SocketAddr::V4(peer))=stream.peer_addr() else {continue};
        if !is_coco_client_address(peer.ip()){continue;}
        let _=stream.set_read_timeout(Some(Duration::from_secs(3)));
        let mut line=String::new();
        let Ok(reader)=stream.try_clone() else {continue};
        if BufReader::new(reader.take(64)).read_line(&mut line).is_err(){continue;}
        let Some(name)=parse_name_request(&line) else {continue};
        let ip=peer.ip().to_string();
        let Some(list)=get(format!("{API}/{NETWORK_ID}/member")) else {continue};
        let records:Vec<(String,Value)>=list.as_object().map(|members|members.keys()
            .filter_map(|node|get(format!("{API}/{NETWORK_ID}/member/{node}")).map(|member|(node.clone(),member))).collect()).unwrap_or_default();
        let Some(node)=member_with_address(records.iter().map(|(node,member)|(node.as_str(),member)),&ip) else {continue};
        let current=records.iter().find(|(id,_)|*id==node).and_then(|(_,member)|member.get("name")).and_then(Value::as_str);
        let stored=current==Some(name.as_str())||client.post(format!("{API}/{NETWORK_ID}/member/{node}")).header("X-ZT1-Auth",&token)
            .header("Content-Type","application/json").body(serde_json::json!({"name":name}).to_string()).send()
            .is_ok_and(|response|response.status().is_success());
        if stored{
            if current!=Some(name.as_str()){crate::services::diagnostics::log("zerotier",&format!("{name} = {ip} ({node})"));}
            let _=stream.write_all(b"OK\n");
        }
    }
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

    #[test]
    fn only_a_valid_profile_name_reaches_the_controller(){
        assert_eq!(parse_name_request("COCO-NAME 1 Nicoquito\n").as_deref(),Some("Nicoquito"));
        assert_eq!(parse_name_request("COCO-NAME 1 smol_bird\r\n").as_deref(),Some("smol_bird"));
        for bad in ["COCO-NAME 1 ab\n","COCO-NAME 1 a\"b,c\n","COCO-NAME 1 nombre con espacios\n",
            "COCO-NAME 1 muchisimosCaracteres\n","COCO-NAME 2 Nicoquito\n","Nicoquito\n",""]{
            assert_eq!(parse_name_request(bad),None,"{bad:?}");
        }
    }

    /// Host PC only: receive this PC's own profile name and read it back from the controller.
    #[test]
    #[ignore]
    fn real_host_stores_a_sent_profile_name(){
        let token=token().expect("ZeroTier token");
        assert!(is_host(),"this PC must run Coco's controller");
        let name=profile_name().expect("profile name");
        let receiver=token.clone();
        std::thread::spawn(move||receive_names(receiver));
        let mut acknowledged=false;
        for _ in 0..20{std::thread::sleep(Duration::from_millis(500));if send_name(&name){acknowledged=true;break;}}
        assert!(acknowledged,"host did not answer OK");
        let client=reqwest::blocking::Client::builder().no_proxy().build().unwrap();
        let text=client.get(format!("{API}/{NETWORK_ID}/member")).header("X-ZT1-Auth",&token).send().unwrap().text().unwrap();
        let list:Value=serde_json::from_str(&text).unwrap();
        let named=list.as_object().unwrap().keys().any(|node|{
            let member:Value=serde_json::from_str(&client.get(format!("{API}/{NETWORK_ID}/member/{node}")).header("X-ZT1-Auth",&token).send().unwrap().text().unwrap()).unwrap();
            member.get("ipAssignments").and_then(Value::as_array).is_some_and(|ips|ips.iter().any(|ip|ip.as_str()==Some(HOST_IP)))
                &&member.get("name").and_then(Value::as_str)==Some(name.as_str())
        });
        assert!(named,"{name} not stored on the member at {HOST_IP}");
    }

    #[test]
    fn the_name_goes_to_the_member_that_owns_the_address(){
        let a=json!({"ipAssignments":["10.77.37.11"]});
        let b=json!({"ipAssignments":["10.77.37.110"]});
        let none=json!({});
        let records=[("296cb49bb5",&a),("bbbbbbbbbb",&b),("cccccccccc",&none)];
        assert_eq!(member_with_address(records,"10.77.37.11").as_deref(),Some("296cb49bb5"));
        assert_eq!(member_with_address(records,"10.77.37.110").as_deref(),Some("bbbbbbbbbb"));
        assert_eq!(member_with_address(records,"10.77.37.12"),None);
        assert!(is_coco_client_address(&"10.77.37.1".parse().unwrap()));
        assert!(!is_coco_client_address(&"192.168.80.191".parse().unwrap()));
        assert!(!is_coco_client_address(&"10.77.38.5".parse().unwrap()));
    }
}
