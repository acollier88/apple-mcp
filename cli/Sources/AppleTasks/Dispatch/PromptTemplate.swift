import Foundation

/// Prompt rendering for dispatched agents (#27).
enum PromptTemplate {
    /// Single-pass `{name}` substitution. The template is scanned once, left
    /// to right; a substituted value is copied to the output and never
    /// re-scanned, so a title containing `{notes}` or `{claimTag}` stays
    /// literal text. Placeholders with no entry in `values` (e.g. an
    /// unknown `{foo}`) are left exactly as written.
    static func render(_ template: String, values: [String: String]) -> String {
        var out = ""
        out.reserveCapacity(template.count)
        var i = template.startIndex
        while i < template.endIndex {
            let ch = template[i]
            if ch == "{",
               let close = template[template.index(after: i)...].firstIndex(where: { $0 == "}" || $0 == "{" }),
               template[close] == "}" {
                let name = String(template[template.index(after: i)..<close])
                if let value = values[name] {
                    out += value
                    i = template.index(after: close)
                    continue
                }
            }
            out.append(ch)
            i = template.index(after: i)
        }
        return out
    }

    /// Untrusted-data block markers used by the default template. A custom
    /// template can use the same lines; `neutralise` keeps a value from
    /// forging them.
    static func begin(_ label: String) -> String { "<<<BEGIN UNTRUSTED \(label)>>>" }
    static func end(_ label: String) -> String { "<<<END UNTRUSTED \(label)>>>" }

    /// Break every `<<<` / `>>>` run in untrusted text so it cannot open or
    /// close a marker line. Visible (spaces), not silent stripping, so the
    /// agent still sees roughly what the human wrote.
    static func neutralise(_ text: String) -> String {
        var s = text
        while s.contains("<<<") { s = s.replacingOccurrences(of: "<<<", with: "<< <") }
        while s.contains(">>>") { s = s.replacingOccurrences(of: ">>>", with: "> > >") }
        return s
    }
}

extension Dispatch {
    /// The rendered task prompt (before lane/tag-specific trailers). Title,
    /// notes and list are untrusted and are neutralised whatever the
    /// template looks like; `{id}` and `{claimTag}` are ours.
    static func taskPrompt(template: String, taskId: String, list: String,
                           title: String, notes: String?, claimTag: String) -> String {
        PromptTemplate.render(template, values: [
            "id": taskId,
            "list": PromptTemplate.neutralise(list),
            "title": PromptTemplate.neutralise(title),
            "notes": PromptTemplate.neutralise(notes ?? "(none)"),
            "claimTag": claimTag,
        ])
    }
}
