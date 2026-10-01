// Frozen b22d9d3 sharing decisions for diagnostics parity.
import Foundation

/// Read sharing for one read-only traversal group. No value/text, result or
/// authentication verdict survives this scope. Reused structure is validated
/// before its caller may accept the result or perform an action.
public final class AXTraversalReadScope {
    private struct Key: Hashable {
        let element: UIElement
        static func == (lhs: Key, rhs: Key) -> Bool {
            CFEqual(lhs.element.axElement, rhs.element.axElement)
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(CFHash(element.axElement))
        }
    }
    private struct Entry {
        let element: UIElement
        let role: String
        let children: [UIElement]
        var reused: Bool
    }
    private struct RootRead {
        let element: UIElement
        let children: [UIElement]
    }

    struct Counts {
        var hits = 0
        var visited = 0
        var liveBatches = 0
        var validationBatches = 0
        var rootReads = 0
        var validationRootReads = 0
        var uncertain = 0
        var distinct = 0
        var reused = 0
        var admissionChecks = 0
        var predictedHits = 0
        var predictedNodes = 0
        var guardAXCost = 0
        var activated = 0
    }
    enum Validation: Int {
        case valid = 0
        case limit = 1
        case inconsistentRoot = 2
        case uncertainStructure = 3
        case changedStructure = 4
        case uncertainRoot = 5
        case changedRoot = 6
    }

    private let maxEntries: Int
    private let maxChildReferences: Int
    private var childReferences = 0
    private var entries: [Key: Entry] = [:]
    private var entryOrder: [Key] = []
    private var roots: [Key: RootRead] = [:]
    private var rootOrder: [Key] = []
    private var invalid: Validation?
    private var reuseKeys: Set<Key>?
    private(set) var counts = Counts()

    init(maxEntries: Int = 4096, maxChildReferences: Int = 32768) {
        self.maxEntries = maxEntries
        self.maxChildReferences = maxChildReferences
    }

    /// Learn using the original live reads first. Reuse starts only when the
    /// already-read graph predicts more saved AX calls than all safety checks.
    /// Unknown structure ends that root's credit; it never becomes an empty
    /// cached subtree. This planner does no AX calls or text reads.
    func considerReuse(
        in remainingRoots: ArraySlice<UIElement>, roles: Set<String>,
        roleLimits: [String: Int], maxNodes: Int, guardAXCost: Int
    ) {
        guard reuseKeys == nil, invalid == nil, !entries.isEmpty else { return }
        counts.admissionChecks += 1
        var predictedHits = 0
        var keys = Set<Key>()
        for root in remainingRoots {
            let rootKey = Key(element: root)
            guard let children = roots[rootKey]?.children ?? entries[rootKey]?.children else { continue }
            var queue = Array(children.prefix(maxNodes))
            var index = 0, saturated = 0
            var matches: [String: Int] = [:]
            while index < queue.count, index < maxNodes, saturated < roles.count {
                let key = Key(element: queue[index])
                guard let saved = entries[key] else { break }
                index += 1
                predictedHits += 1
                keys.insert(key)
                if roles.contains(saved.role) {
                    let limit = roleLimits[saved.role] ?? .max
                    if matches[saved.role, default: 0] < limit {
                        matches[saved.role, default: 0] += 1
                        if matches[saved.role] == limit { saturated += 1 }
                    }
                }
                if saturated < roles.count, index < maxNodes {
                    // The BFS cannot visit beyond maxNodes, even with cycles.
                    queue.append(contentsOf: saved.children.prefix(maxNodes - queue.count))
                }
            }
        }
        guard predictedHits - keys.count > guardAXCost else { return }
        reuseKeys = keys
        counts.predictedHits = predictedHits
        counts.predictedNodes = keys.count
        counts.guardAXCost = guardAXCost
        counts.activated = 1
    }

    func children(atRoot root: UIElement) -> [UIElement] {
        counts.rootReads += 1
        let read = root.childrenRead()
        let key = Key(element: root)
        guard read.complete else {
            counts.uncertain += 1
            if entries[key] != nil || roots[key] != nil { invalid = .uncertainRoot }
            // Preserve the original empty-on-error result; never reuse it.
            return read.children
        }
        if let saved = entries[key], !Self.sameElements(saved.children, read.children) {
            invalid = .changedRoot
        }
        if let previous = roots[key] {
            if !Self.sameElements(previous.children, read.children) {
                invalid = .inconsistentRoot
            }
        } else if invalid == nil {
            if reserve(children: read.children.count) {
                roots[key] = RootRead(element: root, children: read.children)
                rootOrder.append(key)
            }
        }
        return read.children
    }

    func roleAndChildren(of element: UIElement) -> (role: String?, children: [UIElement]) {
        counts.visited += 1
        let key = Key(element: element)
        if invalid == nil, reuseKeys?.contains(key) == true, var saved = entries[key] {
            counts.hits += 1
            if !saved.reused {
                saved.reused = true
                entries[key] = saved
                counts.reused += 1
            }
            return (saved.role, saved.children)
        }
        counts.liveBatches += 1
        let read = element.roleAndChildrenRead()
        if read.complete, let role = read.role, invalid == nil {
            if let saved = entries[key] {
                // Learning must never replace the first observation with a
                // later structure and then reuse a mixed snapshot.
                if saved.role != role || !Self.sameElements(saved.children, read.children) {
                    invalid = .changedStructure
                }
            } else if reuseKeys == nil, reserve(children: read.children.count) {
                entries[key] = Entry(element: element, role: role, children: read.children, reused: false)
                entryOrder.append(key)
                counts.distinct += 1
            }
        } else if !read.complete {
            counts.uncertain += 1
            if entries[key] != nil { invalid = .uncertainStructure }
        }
        return (read.role, read.children)
    }

    /// Only a reused value can make the shared walk differ from the original
    /// reads. Validate those values and every successful root-children read.
    /// Nil/error children are not an established empty array and are rejected.
    func validateReusedStructure() -> Validation {
        if let invalid { return invalid }
        guard counts.hits > 0 else { return .valid }
        for key in entryOrder {
            guard let saved = entries[key], saved.reused else { continue }
            counts.validationBatches += 1
            let current = saved.element.roleAndChildrenRead()
            guard current.complete else { return .uncertainStructure }
            guard current.role == saved.role, Self.sameElements(current.children, saved.children) else {
                return .changedStructure
            }
        }
        for key in rootOrder {
            guard let saved = roots[key] else { continue }
            counts.validationRootReads += 1
            let current = saved.element.childrenRead()
            guard current.complete else { return .uncertainRoot }
            guard Self.sameElements(current.children, saved.children) else { return .changedRoot }
        }
        return .valid
    }

    func discard() {
        entries.removeAll(keepingCapacity: false)
        entryOrder.removeAll(keepingCapacity: false)
        roots.removeAll(keepingCapacity: false)
        rootOrder.removeAll(keepingCapacity: false)
        childReferences = 0
        reuseKeys = nil
    }

    private func reserve(children: Int) -> Bool {
        guard entries.count + roots.count < maxEntries,
              children <= maxChildReferences - childReferences else {
            invalid = .limit
            return false
        }
        childReferences += children
        return true
    }

    static func sameElements(_ lhs: [UIElement], _ rhs: [UIElement]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            CFEqual($0.axElement, $1.axElement)
        }
    }
}
