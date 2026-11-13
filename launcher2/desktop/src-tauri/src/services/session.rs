//! Read-only client for the existing wire protocol, implemented fully in Rust.
//! Future native hosting can reuse the same validation and state transitions.
use serde::{Deserialize, Serialize};
use std::io::{Read, Write};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpStream};
use std::time::Duration;
use tauri::State;
use time::{format_description::well_known::Rfc3339, OffsetDateTime};

#[derive(Clone, Deserialize)]
#[serde(rename_all="camelCase")]
struct Discovery {
    host: String,
    port: u16,
    timeout_ms: u64,
    max_response_bytes: usize,
    max_ttl_seconds: i64,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all="camelCase")]
struct Experience {
    id: String,
    pack_version: String,
    host: String,
    port: u16,
}

#[derive(Clone, Deserialize)]
struct SessionConfig {
    discovery: Discovery,
    experiences: Vec<Experience>,
}

#[derive(Deserialize)]
#[serde(rename_all="camelCase")]
struct Announcement {
    schema_version: u32,
    state: String,
    session_id: Option<String>,
    experience_id: Option<String>,
    pack_version: Option<String>,
    host: Option<String>,
    port: Option<u16>,
    force_join: Option<bool>,
    issued_at_utc: Option<String>,
    expires_at_utc: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all="camelCase")]
pub struct SessionStatus {
    state: String,
    experience_id: Option<String>,
    force_join: bool,
    reason: Option<String>,
}

impl SessionStatus {
    fn offline(reason: impl Into<String>) -> Self {
        Self {state:"offline".into(),experience_id:None,force_join:false,reason:Some(reason.into())}
    }
}

fn load_config() -> Result<SessionConfig,String> {
    serde_json::from_str(include_str!("../../resources/session-config.json"))
        .map_err(|e|format!("Configuración de sesión inválida: {e}"))
}

fn validate(payload:&[u8],config:&SessionConfig,now:OffsetDateTime)->Result<SessionStatus,String>{
    let entry:Announcement=serde_json::from_slice(payload).map_err(|_|"Respuesta de sesión inválida")?;
    if entry.schema_version!=1{return Err("Versión de sesión desconocida".into());}
    if entry.state=="offline"{return Ok(SessionStatus::offline("Sin partida activa"));}
    if !matches!(entry.state.as_str(),"preparing"|"ready"|"stopping"){
        return Err("Estado de partida desconocido".into());
    }
    let session_id=entry.session_id.ok_or("Falta identificador de sesión")?;
    if !(32..=36).contains(&session_id.len()) || !session_id.chars().all(|x|x.is_ascii_hexdigit()||x=='-'){
        return Err("Identificador de sesión inválido".into());
    }
    let id=entry.experience_id.ok_or("Falta experiencia")?;
    let target=config.experiences.iter().find(|x|x.id==id).ok_or("Experiencia desconocida")?;
    if entry.pack_version.as_deref()!=Some(target.pack_version.as_str()){
        return Err("Versión de paquete distinta".into());
    }
    if entry.host.as_deref()!=Some(target.host.as_str()) || entry.port!=Some(target.port){
        return Err("Endpoint de sesión distinto".into());
    }
    let parse=|value:Option<String>|->Result<OffsetDateTime,String>{
        OffsetDateTime::parse(&value.ok_or("Marca de tiempo faltante")?,&Rfc3339)
            .map_err(|_|"Marca de tiempo inválida".into())
    };
    let issued=parse(entry.issued_at_utc)?;
    let expires=parse(entry.expires_at_utc)?;
    if expires<=now || issued>now+time::Duration::seconds(30) || expires<=issued ||
       expires-issued>time::Duration::seconds(config.discovery.max_ttl_seconds+1){
        return Err("Sesión caducada o con reloj inválido".into());
    }
    Ok(SessionStatus {state:entry.state,experience_id:Some(id),force_join:entry.force_join.unwrap_or(true),reason:None})
}

fn read_payload(stream:&mut TcpStream,max_response_bytes:usize)->Result<Vec<u8>,String>{
    stream.write_all(b"COCO-SESSION 1\n").map_err(|_|"No se pudo consultar sesión")?;
    let mut header=Vec::with_capacity(64);
    loop{
        let mut byte=[0u8];
        if stream.read_exact(&mut byte).is_err(){return Err("Encabezado incompleto".into());}
        if byte[0]==b'\n'{break;}
        if byte[0]==b'\r'{continue;}
        if header.len()>=63 || !byte[0].is_ascii(){return Err("Encabezado demasiado largo".into());}
        header.push(byte[0]);
    }
    let line=std::str::from_utf8(&header).map_err(|_|"Encabezado inválido")?;
    let number=line.strip_prefix("COCO-SESSION 1 ").ok_or("Protocolo de sesión desconocido")?;
    if number.is_empty()||number.len()>5||!number.bytes().all(|v|v.is_ascii_digit()){
        return Err("Longitud de sesión inválida".into());
    }
    let length=number.parse::<usize>().map_err(|_|"Longitud inválida")?;
    if length<2||length>max_response_bytes{return Err("Respuesta demasiado grande".into());}
    let mut bytes=vec![0u8;length];
    stream.read_exact(&mut bytes).map_err(|_|"Respuesta incompleta")?;
    Ok(bytes)
}

fn discover(config:&SessionConfig,endpoint:SocketAddr)->SessionStatus{
    let timeout=Duration::from_millis(config.discovery.timeout_ms.clamp(100,10_000));
    let stream=TcpStream::connect_timeout(&endpoint,timeout);
    let mut stream=match stream {Ok(value)=>value,Err(_)=>return SessionStatus::offline("Sin conexión al host")};
    let _=stream.set_read_timeout(Some(timeout));
    let _=stream.set_write_timeout(Some(timeout));
    match read_payload(&mut stream,config.discovery.max_response_bytes)
        .and_then(|payload|validate(&payload,config,OffsetDateTime::now_utc())) {
        Ok(status)=>status,
        Err(error)=>SessionStatus::offline(error),
    }
}

#[derive(Default)]
pub struct SessionState;

#[tauri::command]
pub async fn get_session_status(_state:State<'_,SessionState>)->Result<SessionStatus,String>{
    let config=load_config()?;
    let ip=config.discovery.host.parse::<Ipv4Addr>().map_err(|_|"Host de sesión inválido")?;
    let endpoint=SocketAddr::new(IpAddr::V4(ip),config.discovery.port);
    tauri::async_runtime::spawn_blocking(move||discover(&config,endpoint)).await
        .map_err(|e|format!("Consulta interrumpida: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::thread;

    #[test]
    fn rejects_forged_endpoint_and_expired_session(){
        let config=load_config().unwrap();
        let first=config.experiences.iter().find(|x|x.id=="cobbleverse").unwrap();
        let now=OffsetDateTime::now_utc();
        let payload=serde_json::json!({
            "schemaVersion":1,"state":"ready","sessionId":"01234567-0123-0123-0123-0123456789ab",
            "experienceId":first.id,"packVersion":first.pack_version,"host":"attacker.invalid","port":first.port,
            "issuedAtUtc":now.format(&Rfc3339).unwrap(),"expiresAtUtc":(now+time::Duration::seconds(30)).format(&Rfc3339).unwrap()
        });
        assert!(validate(payload.to_string().as_bytes(),&config,now).unwrap_err().contains("Endpoint"));
        let mut actual=payload;
        actual["host"]=serde_json::Value::String(first.host.clone());
        actual["expiresAtUtc"]=serde_json::Value::String((now-time::Duration::seconds(1)).format(&Rfc3339).unwrap());
        assert!(validate(actual.to_string().as_bytes(),&config,now).is_err());
    }

    #[test]
    fn parses_bounded_local_protocol_without_contacting_real_host(){
        let listener=TcpListener::bind("127.0.0.1:0").unwrap();
        let addr=listener.local_addr().unwrap();
        let handle=thread::spawn(move||{
            let (mut socket,_)=listener.accept().unwrap();
            let mut request=[0u8;15];socket.read_exact(&mut request).unwrap();
            assert_eq!(&request,b"COCO-SESSION 1\n");
            let json=b"{\"schemaVersion\":1,\"state\":\"offline\"}";
            socket.write_all(format!("COCO-SESSION 1 {}\n",json.len()).as_bytes()).unwrap();
            socket.write_all(json).unwrap();
        });
        let config=load_config().unwrap();
        let status=discover(&config,addr);
        assert_eq!(status.state,"offline");
        assert_eq!(status.reason.as_deref(),Some("Sin partida activa"));
        handle.join().unwrap();
    }
}
