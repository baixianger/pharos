use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Deserialize, Serialize)]
pub struct AdapterRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub jsonrpc: Option<String>,
    pub id: Value,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct AdapterResponse {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub jsonrpc: Option<String>,
    pub id: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<AdapterError>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct AdapterError {
    pub code: i64,
    pub message: String,
}

impl AdapterResponse {
    pub fn success(id: Value, result: Value) -> Self {
        Self { jsonrpc: None, id, result: Some(result), error: None }
    }

    pub fn failure(id: Value, message: impl Into<String>) -> Self {
        Self {
            jsonrpc: None,
            id,
            result: None,
            error: Some(AdapterError { code: -32603, message: message.into() }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_defaults_missing_params_to_null() {
        let request: AdapterRequest = serde_json::from_str(
            r#"{"id":"one","method":"thread/list"}"#,
        ).unwrap();
        assert_eq!(request.params, Value::Null);
    }

    #[test]
    fn success_omits_error() {
        let response = AdapterResponse::success(Value::from(1), serde_json::json!({"ok": true}));
        let value = serde_json::to_value(response).unwrap();
        assert!(value.get("error").is_none());
        assert_eq!(value["result"]["ok"], true);
    }
}
