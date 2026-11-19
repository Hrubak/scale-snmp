//! HyperCore REST client.
//!
//! TLS is rustls (pure Rust), so TLS 1.3 works on Windows 10 without Schannel,
//! curl, .NET, or an external openssl.exe. HyperCore nodes use self-signed
//! certificates, so the certificate chain is not checked (the handshake
//! signature still is). Credentials stay in memory and are never logged.

use crate::util::{api_path, public_error};
use base64::Engine;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{verify_tls12_signature, verify_tls13_signature, CryptoProvider};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, ClientConnection, DigitallySignedStruct, SignatureScheme};
use std::io::Read;
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

pub const USER_AGENT: &str = concat!("ScaleHyperCoreAPIToolkit/", env!("CARGO_PKG_VERSION"));

#[derive(Debug)]
struct AcceptSelfSigned(Arc<CryptoProvider>);

impl ServerCertVerifier for AcceptSelfSigned {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls12_signature(
            message,
            cert,
            dss,
            &self.0.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls13_signature(
            message,
            cert,
            dss,
            &self.0.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}

fn tls_config(versions: &[&'static rustls::SupportedProtocolVersion]) -> Arc<ClientConfig> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let cfg = ClientConfig::builder_with_provider(provider.clone())
        .with_protocol_versions(versions)
        .expect("rustls protocol versions")
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(AcceptSelfSigned(provider)))
        .with_no_client_auth();
    Arc::new(cfg)
}

/// TLS 1.3 and 1.2, shared by every request.
fn default_tls() -> Arc<ClientConfig> {
    static CFG: OnceLock<Arc<ClientConfig>> = OnceLock::new();
    CFG.get_or_init(|| tls_config(&[&rustls::version::TLS13, &rustls::version::TLS12]))
        .clone()
}

#[derive(Clone, Debug)]
pub struct Response {
    /// HTTP status, or 0 when no response came back (connect/TLS failure).
    pub code: u16,
    pub body: String,
}

impl Response {
    pub fn ok(&self) -> bool {
        (200..300).contains(&self.code)
    }
    pub fn code_text(&self) -> String {
        if self.code == 0 {
            "000".into()
        } else {
            self.code.to_string()
        }
    }
}

#[derive(Clone)]
pub struct Client {
    host: String,
    auth: Option<String>,
}

impl Client {
    pub fn new(host: &str, user: &str, password: &str) -> Self {
        let token = base64::engine::general_purpose::STANDARD.encode(format!("{user}:{password}"));
        Self {
            host: host.trim().to_string(),
            auth: Some(format!("Basic {token}")),
        }
    }

    /// No Authorization header (TLS test, no credentials sent).
    pub fn anonymous(host: &str) -> Self {
        Self {
            host: host.trim().to_string(),
            auth: None,
        }
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn url(&self, path: &str) -> String {
        let p = api_path(path);
        if p.starts_with("http://") || p.starts_with("https://") {
            p
        } else {
            format!("https://{}{}", self.host, p)
        }
    }

    pub fn request(&self, method: &str, path: &str, body: &str, timeout: Duration) -> Response {
        let agent = ureq::AgentBuilder::new()
            .tls_config(default_tls())
            .timeout(timeout)
            .user_agent(USER_AGENT)
            .build();
        let url = self.url(path);
        let mut req = agent
            .request(method, &url)
            .set("Accept", "application/json");
        if let Some(a) = &self.auth {
            req = req.set("Authorization", a);
        }
        let sends_body = !body.is_empty() && matches!(method, "POST" | "PATCH" | "PUT" | "DELETE");
        let result = if sends_body {
            req.set("Content-Type", "application/json")
                .send_string(body)
        } else {
            req.call()
        };
        match result {
            Ok(resp) => read_response(resp),
            Err(ureq::Error::Status(_, resp)) => read_response(resp),
            Err(ureq::Error::Transport(t)) => Response {
                code: 0,
                body: public_error(&t.to_string()),
            },
        }
    }

    pub fn get(&self, path: &str) -> Response {
        self.request("GET", path, "", Duration::from_secs(60))
    }
}

fn read_response(resp: ureq::Response) -> Response {
    let code = resp.status();
    let mut body = String::new();
    let _ = resp
        .into_reader()
        .take(64 * 1024 * 1024)
        .read_to_string(&mut body);
    Response { code, body }
}

/// Handshake only (no HTTP, no credentials). Returns "TLS 1.3 TLS13_AES_256_GCM_SHA384" or an error.
pub fn probe_tls(
    host: &str,
    versions: &[&'static rustls::SupportedProtocolVersion],
) -> Result<String, String> {
    let cfg = tls_config(versions);
    let name = ServerName::try_from(host.to_string()).map_err(|e| e.to_string())?;
    let mut conn = ClientConnection::new(cfg, name).map_err(|e| e.to_string())?;
    let addr = (host, 443)
        .to_socket_addrs()
        .map_err(|e| format!("resolve {host}: {e}"))?
        .next()
        .ok_or_else(|| format!("resolve {host}: no address"))?;
    let mut sock = TcpStream::connect_timeout(&addr, Duration::from_secs(10))
        .map_err(|e| format!("TCP {addr}: {e}"))?;
    sock.set_read_timeout(Some(Duration::from_secs(10))).ok();
    sock.set_write_timeout(Some(Duration::from_secs(10))).ok();
    while conn.is_handshaking() {
        conn.complete_io(&mut sock).map_err(|e| e.to_string())?;
    }
    let proto = match conn.protocol_version() {
        Some(rustls::ProtocolVersion::TLSv1_3) => "TLS 1.3",
        Some(rustls::ProtocolVersion::TLSv1_2) => "TLS 1.2",
        _ => "unknown",
    };
    let suite = conn
        .negotiated_cipher_suite()
        .map(|s| format!("{:?}", s.suite()))
        .unwrap_or_default();
    Ok(format!("{proto} {suite}").trim().to_string())
}

pub fn probe_tls13(host: &str) -> Result<String, String> {
    probe_tls(host, &[&rustls::version::TLS13])
}

pub fn probe_tls12(host: &str) -> Result<String, String> {
    probe_tls(host, &[&rustls::version::TLS12])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urls() {
        let c = Client::new("10.0.0.1", "admin", "pw");
        assert_eq!(c.url("/v1/Cluster"), "https://10.0.0.1/rest/v1/Cluster");
        assert_eq!(c.url("/rest/v1/Node"), "https://10.0.0.1/rest/v1/Node");
        assert_eq!(
            c.url("/update/update_status.json"),
            "https://10.0.0.1/update/update_status.json"
        );
    }

    #[test]
    fn configs_build() {
        let _ = default_tls();
        let _ = tls_config(&[&rustls::version::TLS13]);
    }
}
