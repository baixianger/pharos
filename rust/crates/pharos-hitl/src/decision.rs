//! Extended human decision model for pending approvals.
//!
//! The frozen `pharos_api::ApprovalDecision` contract only knows
//! `allowedOnce` / `allowedAlways` / `rejected`. The workspace UI additionally
//! needs:
//!
//! - `cancelled` — "cancel the in-flight turn" (a distinct, non-retryable
//!   decision that must never be confused with `rejected`), and
//! - structured questionnaire answers attached to a decision.
//!
//! [`StoredDecision`] is the durable superset. It serializes to the same JSON
//! strings as the frozen enum for the three legacy variants, so pending
//! approval stores written by earlier builds keep loading, and maps back with
//! [`StoredDecision::to_api`].

use pharos_api::{ApprovalDecision, ApprovalKind};
use serde::{Deserialize, Serialize};

use crate::approval_store::ApprovalStoreError;

/// One human answer to one question of a structured questionnaire approval.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuestionnaireAnswer {
    /// Question id from `ApprovalKind::StructuredQuestionnaire::questions`.
    pub question_id: String,
    /// Selected option values (empty when the human only typed free text).
    #[serde(default)]
    pub selected: Vec<String>,
    /// Optional free-text answer ("Other answer").
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
}

/// Durable superset of [`ApprovalDecision`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum StoredDecision {
    AllowedOnce,
    AllowedAlways,
    Rejected,
    /// Cancel the in-flight turn. Only offered when the adapter announced
    /// `"cancelled"` in the approval's `availableChoices`.
    Cancelled,
}

impl StoredDecision {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::AllowedOnce => "allowedOnce",
            Self::AllowedAlways => "allowedAlways",
            Self::Rejected => "rejected",
            Self::Cancelled => "cancelled",
        }
    }

    /// Map back to the frozen contract enum; `Cancelled` has no frozen
    /// equivalent and therefore returns `None`.
    pub fn to_api(self) -> Option<ApprovalDecision> {
        match self {
            Self::AllowedOnce => Some(ApprovalDecision::AllowedOnce),
            Self::AllowedAlways => Some(ApprovalDecision::AllowedAlways),
            Self::Rejected => Some(ApprovalDecision::Rejected),
            Self::Cancelled => None,
        }
    }

    /// True when the decision is representable by the frozen API contract.
    pub fn is_api_compatible(self) -> bool {
        self.to_api().is_some()
    }
}

impl From<ApprovalDecision> for StoredDecision {
    fn from(decision: ApprovalDecision) -> Self {
        match decision {
            ApprovalDecision::AllowedOnce => Self::AllowedOnce,
            ApprovalDecision::AllowedAlways => Self::AllowedAlways,
            ApprovalDecision::Rejected => Self::Rejected,
        }
    }
}

impl TryFrom<StoredDecision> for ApprovalDecision {
    type Error = ApprovalStoreError;

    fn try_from(decision: StoredDecision) -> Result<Self, Self::Error> {
        decision.to_api().ok_or_else(|| {
            ApprovalStoreError::Invalid(
                "decision `cancelled` has no frozen API representation".into(),
            )
        })
    }
}

/// Validate a decision (and optional questionnaire answers) against the
/// approval it belongs to.
///
/// Rules:
/// - `cancelled` must have been offered through `available_choices` (when the
///   adapter announced choices at all) — the UI only shows the button then.
/// - questionnaire answers are only valid for `StructuredQuestionnaire`
///   approvals, must reference existing question ids exactly once, and each
///   selected value must be one of that question's options when options exist.
pub fn validate_decision(
    kind: &ApprovalKind,
    available_choices: Option<&[String]>,
    decision: StoredDecision,
    answers: Option<&[QuestionnaireAnswer]>,
) -> Result<(), ApprovalStoreError> {
    if decision == StoredDecision::Cancelled
        && let Some(choices) = available_choices
        && !choices.iter().any(|choice| choice == "cancelled")
    {
        return Err(ApprovalStoreError::Invalid(
            "decision `cancelled` was not offered by the adapter".into(),
        ));
    }

    let Some(answers) = answers.filter(|answers| !answers.is_empty()) else {
        return Ok(());
    };

    let ApprovalKind::StructuredQuestionnaire { questions, .. } = kind else {
        return Err(ApprovalStoreError::Invalid(
            "questionnaire answers are only valid for structured questionnaire approvals".into(),
        ));
    };

    let mut seen = std::collections::BTreeSet::new();
    for answer in answers {
        if !seen.insert(answer.question_id.as_str()) {
            return Err(ApprovalStoreError::Invalid(format!(
                "duplicate answer for question {:?}",
                answer.question_id
            )));
        }
        let Some(question) = questions
            .iter()
            .find(|question| question.id == answer.question_id)
        else {
            return Err(ApprovalStoreError::Invalid(format!(
                "unknown question id {:?}",
                answer.question_id
            )));
        };
        if question.options.is_empty() {
            continue;
        }
        for value in &answer.selected {
            if !question.options.iter().any(|option| option == value) {
                return Err(ApprovalStoreError::Invalid(format!(
                    "answer value {value:?} is not an option of question {:?}",
                    answer.question_id
                )));
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use pharos_api::QuestionOption;
    use serde_json::json;

    use super::*;

    fn questionnaire() -> ApprovalKind {
        ApprovalKind::StructuredQuestionnaire {
            intent: "plan".into(),
            questions: vec![
                QuestionOption {
                    id: "q1".into(),
                    question: "Which env?".into(),
                    options: vec!["prod".into(), "staging".into()],
                    is_multi_select: false,
                },
                QuestionOption {
                    id: "q2".into(),
                    question: "Notes".into(),
                    options: vec![],
                    is_multi_select: false,
                },
            ],
        }
    }

    #[test]
    fn legacy_decisions_serialize_like_the_frozen_contract() {
        for (stored, api) in [
            (StoredDecision::AllowedOnce, ApprovalDecision::AllowedOnce),
            (
                StoredDecision::AllowedAlways,
                ApprovalDecision::AllowedAlways,
            ),
            (StoredDecision::Rejected, ApprovalDecision::Rejected),
        ] {
            assert_eq!(serde_json::to_value(stored).unwrap(), json!(api));
            assert_eq!(StoredDecision::from(api), stored);
            assert_eq!(stored.to_api(), Some(api));
            assert!(stored.is_api_compatible());
        }
        assert_eq!(
            serde_json::to_value(StoredDecision::Cancelled).unwrap(),
            json!("cancelled")
        );
        assert_eq!(StoredDecision::Cancelled.to_api(), None);
        assert!(!StoredDecision::Cancelled.is_api_compatible());
    }

    #[test]
    fn cancelled_requires_being_offered() {
        let kind = ApprovalKind::ToolPermission {
            tool_name: "shell".into(),
            params: json!({}),
            explanation: None,
        };
        let offered = vec!["allowedOnce".to_string(), "cancelled".to_string()];
        assert!(validate_decision(&kind, Some(&offered), StoredDecision::Cancelled, None).is_ok());
        let not_offered = vec!["allowedOnce".to_string(), "rejected".to_string()];
        assert!(
            validate_decision(&kind, Some(&not_offered), StoredDecision::Cancelled, None).is_err()
        );
        // No announced choices: the server does not invent an offer.
        assert!(validate_decision(&kind, None, StoredDecision::Cancelled, None).is_ok());
    }

    #[test]
    fn questionnaire_answers_validate_question_and_option_ids() {
        let kind = questionnaire();
        let good = vec![
            QuestionnaireAnswer {
                question_id: "q1".into(),
                selected: vec!["prod".into()],
                text: None,
            },
            QuestionnaireAnswer {
                question_id: "q2".into(),
                selected: vec![],
                text: Some("ship it".into()),
            },
        ];
        assert!(validate_decision(&kind, None, StoredDecision::AllowedOnce, Some(&good)).is_ok());

        let unknown_question = vec![QuestionnaireAnswer {
            question_id: "nope".into(),
            selected: vec![],
            text: None,
        }];
        assert!(
            validate_decision(
                &kind,
                None,
                StoredDecision::AllowedOnce,
                Some(&unknown_question)
            )
            .is_err()
        );

        let bad_option = vec![QuestionnaireAnswer {
            question_id: "q1".into(),
            selected: vec!["dev".into()],
            text: None,
        }];
        assert!(
            validate_decision(&kind, None, StoredDecision::AllowedOnce, Some(&bad_option)).is_err()
        );

        let duplicate = vec![good[0].clone(), good[0].clone()];
        assert!(
            validate_decision(&kind, None, StoredDecision::AllowedOnce, Some(&duplicate)).is_err()
        );
    }

    #[test]
    fn answers_on_tool_permission_are_rejected() {
        let kind = ApprovalKind::ToolPermission {
            tool_name: "shell".into(),
            params: json!({}),
            explanation: None,
        };
        let answers = vec![QuestionnaireAnswer {
            question_id: "q1".into(),
            selected: vec!["prod".into()],
            text: None,
        }];
        assert!(validate_decision(&kind, None, StoredDecision::Rejected, Some(&answers)).is_err());
    }
}
