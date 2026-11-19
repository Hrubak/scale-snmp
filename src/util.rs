//! Small helpers shared by the UI, the HTTP client, and SuperAudit.

use regex::Regex;
use serde_json::Value;
use std::sync::OnceLock;

/// Final path on the host. `/v1/VirDomain` and `/rest/v1/VirDomain` both become
/// `/rest/v1/VirDomain`. `/update/...` is outside `/rest` and is left alone.
pub fn api_path(path: &str) -> String {
    if path.starts_with("http://") || path.starts_with("https://") {
        return path.to_string();
    }
    if path.starts_with("/update/") {
        return path.to_string();
    }
    if path.starts_with("/rest/") || path == "/rest" {
        return path.to_string();
    }
    if path.starts_with('/') {
        format!("/rest{path}")
    } else {
        format!("/rest/{path}")
    }
}

/// Strip credentials from text before it reaches the log or the UI.
pub fn public_error(text: &str) -> String {
    static AUTH: OnceLock<Regex> = OnceLock::new();
    static SECRET: OnceLock<Regex> = OnceLock::new();
    static WS: OnceLock<Regex> = OnceLock::new();
    let auth = AUTH.get_or_init(|| Regex::new(r"(?i)Authorization:\s*Basic\s+\S+").unwrap());
    let secret = SECRET.get_or_init(|| {
        Regex::new(r#"(?i)(password|communityName)"?\s*[:=]\s*"?[^",\s]+"#).unwrap()
    });
    let ws = WS.get_or_init(|| Regex::new(r"[\r\n]+").unwrap());
    let a = auth.replace_all(text, "Authorization: Basic [redacted]");
    let b = secret.replace_all(&a, "$1=[redacted]");
    let c = ws.replace_all(&b, " ");
    let mut out = c.trim().to_string();
    if out.chars().count() > 400 {
        out = out.chars().take(400).collect::<String>() + "...";
    }
    out
}

/// PowerShell-style `[string]$value` for a JSON value.
pub fn js(v: Option<&Value>) -> String {
    match v {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(s)) => s.clone(),
        Some(Value::Bool(b)) => if *b { "True" } else { "False" }.to_string(),
        Some(Value::Number(n)) => {
            if let Some(i) = n.as_i64() {
                i.to_string()
            } else if let Some(u) = n.as_u64() {
                u.to_string()
            } else {
                let f = n.as_f64().unwrap_or(0.0);
                if f.fract() == 0.0 && f.abs() < 1e15 {
                    format!("{}", f as i64)
                } else {
                    format!("{f}")
                }
            }
        }
        Some(other) => other.to_string(),
    }
}

/// Numeric value of a JSON field. Numeric strings parse; anything else is 0.
pub fn num(v: Option<&Value>) -> f64 {
    match v {
        Some(Value::Number(n)) => n.as_f64().unwrap_or(0.0),
        Some(Value::String(s)) => s.trim().parse().unwrap_or(0.0),
        Some(Value::Bool(b)) if *b => 1.0,
        _ => 0.0,
    }
}

/// PowerShell truthiness for a JSON value.
pub fn truthy(v: Option<&Value>) -> bool {
    match v {
        None | Some(Value::Null) => false,
        Some(Value::Bool(b)) => *b,
        Some(Value::String(s)) => !s.is_empty(),
        Some(Value::Number(n)) => n.as_f64().map(|f| f != 0.0).unwrap_or(false),
        Some(Value::Array(a)) => !a.is_empty(),
        Some(Value::Object(_)) => true,
    }
}

/// Value as a list: arrays stay arrays, null is empty, anything else is one item.
pub fn as_list(v: Option<&Value>) -> Vec<Value> {
    match v {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(a)) => a.clone(),
        Some(other) => vec![other.clone()],
    }
}

/// First record of a REST response (HyperCore returns arrays for most GETs).
pub fn first_record(v: &Value) -> Option<&Value> {
    match v {
        Value::Array(a) => a.first(),
        Value::Null => None,
        other => Some(other),
    }
}

pub fn parse_json(body: &str) -> Option<Value> {
    if body.trim().is_empty() {
        return None;
    }
    serde_json::from_str(body).ok()
}

/// Round half to even, like .NET `MidpointRounding.ToEven`.
pub fn round_even(value: f64, digits: u32) -> f64 {
    let scale = 10f64.powi(digits as i32);
    let x = value * scale;
    let r = x.round();
    let diff = (x - x.trunc()).abs();
    let out = if (diff - 0.5).abs() < 1e-9 {
        let t = x.trunc();
        if (t as i64) % 2 == 0 {
            t
        } else {
            t + x.signum()
        }
    } else {
        r
    };
    out / scale
}

/// Thousands separators on the integer part, invariant culture ("N1"-style).
pub fn group_thousands(fixed: &str) -> String {
    let (sign, rest) = match fixed.strip_prefix('-') {
        Some(r) => ("-", r),
        None => ("", fixed),
    };
    let (int, frac) = match rest.find('.') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, ""),
    };
    let mut out = String::new();
    for (i, ch) in int.chars().enumerate() {
        if i > 0 && (int.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(ch);
    }
    format!("{sign}{out}{frac}")
}

/// HTML-escape text and keep line breaks.
pub fn html_text(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace("\r\n", "<br>")
        .replace(['\n', '\r'], "<br>")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn api_path_prefixes_once() {
        assert_eq!(api_path("/v1/Cluster"), "/rest/v1/Cluster");
        assert_eq!(api_path("/v2/SNMPConfig"), "/rest/v2/SNMPConfig");
        assert_eq!(
            api_path("/update/update_status.json"),
            "/update/update_status.json"
        );
        assert_eq!(api_path("/rest/v1/Node"), "/rest/v1/Node");
        assert_eq!(api_path("v1/Node"), "/rest/v1/Node");
    }

    #[test]
    fn public_error_redacts() {
        let s = public_error("Authorization: Basic abc123==\n{\"password\":\"hunter2\"}");
        assert!(!s.contains("abc123"));
        assert!(!s.contains("hunter2"));
        assert!(!s.contains('\n'));
    }

    #[test]
    fn grouping() {
        assert_eq!(group_thousands("1234567.5"), "1,234,567.5");
        assert_eq!(group_thousands("12.0"), "12.0");
        assert_eq!(group_thousands("-1000.0"), "-1,000.0");
    }

    #[test]
    fn even_rounding() {
        assert_eq!(round_even(2.5, 0), 2.0);
        assert_eq!(round_even(3.5, 0), 4.0);
        assert_eq!(round_even(1.25, 1), 1.2);
    }
}
