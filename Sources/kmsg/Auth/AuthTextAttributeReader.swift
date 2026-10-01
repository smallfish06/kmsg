import ApplicationServices.HIServices

/// Fresh text reads for one acknowledgement inspection. No strings, AX handles
/// or authentication decisions survive a read. Only a local batching circuit
/// and numeric counters remain until the inspection ends.
final class AuthTextAttributeReader {
    private var batchEnabled = true
    private(set) var batchCalls = 0
    private(set) var scalarFallbackSlots = 0

    func read(_ element: UIElement) -> [String?] {
        let names = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute]
        guard batchEnabled else { return names.map { scalar(element, $0) } }

        batchCalls += 1
        let read = element.optionalStringAttributesRead(names)
        var result = read.values
        for index in read.scalarFallbackIndices {
            result[index] = scalar(element, names[index])
        }
        // A failed/malformed batch or four uncertain slots cannot save an IPC.
        // Stop trying for this inspection only; repeated failure costs at most
        // one additional batch call compared with the original scalar path.
        if read.scalarFallbackIndices.count == names.count { batchEnabled = false }
        return result
    }

    private func scalar(_ element: UIElement, _ name: String) -> String? {
        scalarFallbackSlots += 1
        return element.attributeOptional(name)
    }
}
