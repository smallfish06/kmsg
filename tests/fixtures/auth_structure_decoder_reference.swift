// Frozen b22d9d3 UIElement decoder methods; actual AX IPC is replaced by fixtures.
    public func attribute<T>(_ name: String) throws -> T {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(axElement, name as CFString, &value)
        guard error == .success else {
            throw AccessibilityError.axError(error)
        }
        guard let typedValue = value as? T else {
            throw AccessibilityError.typeMismatch
        }
        return typedValue
    }

    public func attributeOptional<T>(_ name: String) -> T? {
        try? attribute(name)
    }

    public func batchAttributes(_ names: [String]) -> [Any?] {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            axElement,
            names as CFArray,
            AXCopyMultipleAttributeOptions(),
            &values
        )
        guard error == .success, let raw = values as? [AnyObject], raw.count == names.count else {
            return [Any?](repeating: nil, count: names.count)
        }
        return raw.map { value -> Any? in
            if CFGetTypeID(value) == AXValueGetTypeID() {
                let axValue = unsafeDowncast(value, to: AXValue.self)
                if AXValueGetType(axValue) == .axError {
                    return nil
                }
            }
            if value is NSNull {
                return nil
            }
            return value
        }
    }

    func optionalStringAttributesRead(_ names: [String]) -> (values: [String?], scalarFallbackIndices: [Int]) {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            axElement, names as CFArray, AXCopyMultipleAttributeOptions(), &values
        )
        guard error == .success, let raw = values as? [AnyObject], raw.count == names.count else {
            return (Array(repeating: nil, count: names.count), Array(names.indices))
        }
        var fallback: [Int] = []
        let strings: [String?] = raw.enumerated().map { index, value in
            if let text = value as? String { return text }
            if CFGetTypeID(value) == AXValueGetTypeID() {
                let axValue = unsafeDowncast(value, to: AXValue.self)
                if AXValueGetType(axValue) == .axError {
                    var slotError = AXError.success
                    if AXValueGetValue(axValue, .axError, &slotError),
                       slotError == .attributeUnsupported || slotError == .noValue {
                        return nil
                    }
                }
            }
            // NSNull, type mismatches and transient AX errors are not an
            // established absence. Preserve scalar error/type semantics.
            fallback.append(index)
            return nil
        }
        return (strings, fallback)
    }

    func roleAndChildrenRead() -> (role: String?, children: [UIElement], complete: Bool) {
        let values = batchAttributes([kAXRoleAttribute, kAXChildrenAttribute])
        let role = values[0] as? String
        let rawChildren = values[1] as? [AXUIElement]
        let children = rawChildren?.map { UIElement($0) } ?? []
        return (role, children, role != nil && rawChildren != nil)
    }

    func childrenRead() -> (children: [UIElement], complete: Bool) {
        let raw: [AXUIElement]? = attributeOptional(kAXChildrenAttribute)
        return (raw?.map { UIElement($0) } ?? [], raw != nil)
    }
