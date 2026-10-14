import XlessCore

extension ASCError: StageReportableError {
    public func stageError(_ stage: Stage) -> XlessError {
        let fix: String
        switch status {
        case 401:
            fix = "App Store Connect rejected the API key: check that ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 belong to the same active key, and that this machine's clock is correct"
        case 403:
            fix = "the API key lacks permission for this request: use a key with the Admin role (App Store Connect → Users and Access → Integrations)"
        case 429, 500...:
            fix = "App Store Connect is unavailable or rate-limiting (already retried); wait a few minutes and re-run"
        default:
            fix = KnownIssues.explain(description) ?? "see the App Store Connect error above"
        }
        return XlessError(stage, description, fix: fix)
    }
}
