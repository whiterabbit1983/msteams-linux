use std::sync::OnceLock;

use serde::Deserialize;
use tauri::Url;

pub const JSON: &str = include_str!("link-policy.json");

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Policy {
    teams_hosts: Vec<String>,
    authentication_hosts: Vec<String>,
}

fn policy() -> &'static Policy {
    static POLICY: OnceLock<Policy> = OnceLock::new();
    POLICY.get_or_init(|| serde_json::from_str(JSON).expect("valid embedded link policy"))
}

pub fn can_open_external(url: &Url) -> bool {
    matches!(url.scheme(), "http" | "https" | "mailto" | "tel")
}

pub fn should_open_external(url: &Url) -> bool {
    if !can_open_external(url) {
        return false;
    }
    let Some(host) = url.host_str() else {
        return true; // mailto: and tel:
    };
    !policy()
        .teams_hosts
        .iter()
        .chain(&policy().authentication_hosts)
        .any(|suffix| host == suffix.as_str() || host.ends_with(&format!(".{suffix}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_and_injected_link_routing_use_the_same_cases() {
        let cases: Vec<serde_json::Value> =
            serde_json::from_str(include_str!("../../tests/link-cases.json")).unwrap();
        for case in cases {
            let url = Url::parse(case["url"].as_str().unwrap()).unwrap();
            assert_eq!(
                should_open_external(&url),
                case["external"].as_bool().unwrap(),
                "{url}"
            );
        }
    }

    #[test]
    fn arbitrary_protocols_cannot_start_programs() {
        for url in [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/plain,x",
            "custom-handler:test",
        ] {
            assert!(!can_open_external(&Url::parse(url).unwrap()));
        }
    }
}
