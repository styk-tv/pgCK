use std::collections::BTreeMap;

#[derive(Debug, Default)]
pub struct Router {
    subscriptions: BTreeMap<String, String>,
}

impl Router {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn add(&mut self, sid: impl Into<String>, pattern: impl Into<String>) {
        self.subscriptions.insert(sid.into(), pattern.into());
    }

    pub fn remove(&mut self, sid: &str) {
        self.subscriptions.remove(sid);
    }

    pub fn matching(&self, subject: &str) -> Vec<String> {
        self.subscriptions
            .iter()
            .filter_map(|(sid, pattern)| matches(pattern, subject).then(|| sid.clone()))
            .collect()
    }
}

pub fn matches(pattern: &str, subject: &str) -> bool {
    let pattern_tokens: Vec<_> = pattern.split('.').collect();
    let subject_tokens: Vec<_> = subject.split('.').collect();
    let mut subject_index = 0;

    for (pattern_index, token) in pattern_tokens.iter().enumerate() {
        match *token {
            ">" => {
                return pattern_index == pattern_tokens.len() - 1
                    && subject_index < subject_tokens.len();
            }
            "*" => {
                if subject_index >= subject_tokens.len() {
                    return false;
                }
                subject_index += 1;
            }
            literal => match subject_tokens.get(subject_index) {
                Some(subject_token) if *subject_token == literal => subject_index += 1,
                _ => return false,
            },
        }
    }

    subject_index == subject_tokens.len()
}

#[cfg(test)]
mod tests {
    use super::Router;

    #[test]
    fn literal_subjects_match_exactly() {
        assert!(super::matches("input.demo.hello", "input.demo.hello"));
        assert!(!super::matches("input.demo.hello", "input.demo.goodbye"));
    }

    #[test]
    fn single_token_wildcard_matches_one_token() {
        assert!(super::matches("input.*.hello", "input.demo.hello"));
        assert!(!super::matches("input.*.hello", "input.demo.extra.hello"));
    }

    #[test]
    fn full_wildcard_matches_tail_tokens() {
        assert!(super::matches("input.>", "input.demo.hello"));
        assert!(!super::matches("input.>", "input"));
    }

    #[test]
    fn router_tracks_add_remove_and_matching_sids() {
        let mut router = Router::new();

        router.add("1", "input.demo.hello");
        router.add("2", "input.*.hello");
        router.add("3", "input.>");
        router.remove("2");

        assert_eq!(router.matching("input.demo.hello"), vec!["1", "3"]);
    }
}
