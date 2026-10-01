import ApplicationServices.HIServices

/// Fresh, bounded input discovery for login-window classification. Final login
/// forms still use the original scalar traversal and current field metadata.
enum AuthInputTraversal {
    static func find(in root: UIElement, limit: Int, maxNodes: Int) -> [UIElement] {
        var results: [UIElement] = []
        var queue = root.children
        var index = 0
        var visited = 0
        var batchEnabled = true

        while index < queue.count && results.count < limit && visited < maxNodes {
            let current = queue[index]
            index += 1
            visited += 1

            // The original search stops before children at either terminal
            // boundary. Use scalar role there to avoid copying a large unused
            // children array even though a pair would cost the same IPC.
            let canBatch = batchEnabled && visited < maxNodes && results.count + 1 < limit
            let snapshot = canBatch ? current.roleAndChildrenRead() : nil
            let role = snapshot?.role ?? current.role ?? ""
            // An uncertain role needs the original scalar read. One failed
            // pair is enough to stop speculative IPC for this walk only.
            if canBatch && snapshot?.role == nil { batchEnabled = false }

            let isInput = role == kAXTextFieldRole || role == kAXTextAreaRole || role == "AXSecureTextField"
            if isInput && current.isEnabled {
                results.append(current)
                if results.count >= limit { break }
            }
            if visited >= maxNodes { break }

            if !isInput && snapshot?.complete == true {
                // The noninput role and children belong to one fresh element
                // snapshot, as in the existing role-based bounded searches.
                queue.append(contentsOf: snapshot!.children)
            } else {
                // Input traversal uses children read freshly after enabled;
                // any children prefetched with role are deliberately unused.
                // Unknown snapshot slots also retain the scalar path.
                queue.append(contentsOf: current.children)
            }
        }

        return results
    }
}
