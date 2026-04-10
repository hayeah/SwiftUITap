import SwiftSyntax
import SwiftSyntaxMacros

public struct SwiftUITapMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let className = type.trimmedDescription

        // Propagate access level from the annotated declaration
        let isPublic = declaration.modifiers.contains { $0.name.text == "public" }
        let access = isPublic ? "public " : ""

        // Extract properties and methods from the class declaration
        let properties = extractProperties(from: declaration)
        let methods = extractMethods(from: declaration)

        let getBody = generateAgentGet(properties: properties)
        let setBody = generateAgentSet(properties: properties)
        let callBody = generateAgentCall(methods: methods)
        let snapshotBody = generateAgentSnapshot(properties: properties)

        let extensionDecl: DeclSyntax = """
        extension \(raw: className): TapDispatchable {
            \(raw: access)func __tapGet(_ path: String) -> TapResult {
                let (head, tail) = TapPath.split(path)
                switch head {
        \(raw: getBody)
                default: return .error("unknown property: \\(head)")
                }
            }

            \(raw: access)func __tapSet(_ path: String, value: Any?) -> TapResult {
                let (head, tail) = TapPath.split(path)
                switch head {
        \(raw: setBody)
                default: return .error("unknown property: \\(head)")
                }
            }

            \(raw: access)func __tapCall(_ method: String, params: [String: Any]) -> TapResult {
                switch method {
        \(raw: callBody)
                default: return .error("unknown method: \\(method)")
                }
            }

            \(raw: access)func __tapSnapshot() -> [String: Any] {
                return [
        \(raw: snapshotBody)
                ]
            }
        }
        """

        guard let extensionSyntax = extensionDecl.as(ExtensionDeclSyntax.self) else {
            return []
        }
        return [extensionSyntax]
    }
}

// MARK: - Property Extraction

struct PropertyInfo {
    let name: String
    let typeStr: String
    let category: PropertyCategory
    let isReadOnly: Bool // let, computed, or no setter
}

enum PropertyCategory {
    case primitive(String)       // String, Int, Double, Bool
    case optionalPrimitive(String) // String?, Int?, etc.
    case array(String)           // [Foo]
    case childState(String)      // any other single identifier — assume TapDispatchable
    case unsupported
}

struct MethodInfo {
    let name: String
    // label: argument label at call site ("_" for unlabeled)
    // internalName: parameter name used in function body
    // jsonKey: key used in JSON params dict (internalName for "_" params, label otherwise)
    let params: [(label: String, internalName: String, jsonKey: String, type: String)]
    let returnType: String? // nil = Void
}

private let primitiveTypes: Set<String> = ["String", "Int", "Double", "Bool"]

func extractProperties(from declaration: some DeclGroupSyntax) -> [PropertyInfo] {
    var results: [PropertyInfo] = []

    for member in declaration.memberBlock.members {
        guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }

        // Skip static
        if varDecl.modifiers.contains(where: { $0.name.text == "static" || $0.name.text == "class" }) {
            continue
        }
        // Skip private/fileprivate
        if varDecl.modifiers.contains(where: { $0.name.text == "private" || $0.name.text == "fileprivate" }) {
            continue
        }

        let isLet = varDecl.bindingSpecifier.text == "let"

        for binding in varDecl.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }

            // Skip if no type annotation
            guard let typeAnnotation = binding.typeAnnotation else { continue }
            let typeStr = typeAnnotation.type.trimmedDescription

            // Check if computed (has accessor block with get but no initializer)
            let isComputed = binding.accessorBlock != nil && binding.initializer == nil

            // Computed properties with a setter are not read-only
            let hasSetter: Bool = {
                guard let accessorBlock = binding.accessorBlock else { return false }
                if case .accessors(let accessorList) = accessorBlock.accessors {
                    return accessorList.contains { $0.accessorSpecifier.text == "set" }
                }
                return false
            }()

            let isReadOnly = isLet || (isComputed && !hasSetter)
            let category = categorizeType(typeStr)

            results.append(PropertyInfo(
                name: name,
                typeStr: typeStr,
                category: category,
                isReadOnly: isReadOnly
            ))
        }
    }

    return results
}

func categorizeType(_ typeStr: String) -> PropertyCategory {
    // Check primitives
    if primitiveTypes.contains(typeStr) {
        return .primitive(typeStr)
    }

    // Check optional primitives: "String?", "Int?", etc.
    if typeStr.hasSuffix("?") {
        let base = String(typeStr.dropLast())
        if primitiveTypes.contains(base) {
            return .optionalPrimitive(base)
        }
        // Optional non-primitive — skip for now
        return .unsupported
    }

    // Check arrays: "[Foo]"
    if typeStr.hasPrefix("[") && typeStr.hasSuffix("]") && !typeStr.contains(":") {
        let elementType = String(typeStr.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        return .array(elementType)
    }

    // Single identifier — assume child state (TapDispatchable at runtime)
    // Must be a simple identifier (no generics, no dots, no brackets)
    let isSimpleIdent = typeStr.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    if isSimpleIdent && !typeStr.isEmpty {
        return .childState(typeStr)
    }

    return .unsupported
}

func extractMethods(from declaration: some DeclGroupSyntax) -> [MethodInfo] {
    var results: [MethodInfo] = []

    for member in declaration.memberBlock.members {
        guard let funcDecl = member.decl.as(FunctionDeclSyntax.self) else { continue }

        // Skip static/class
        if funcDecl.modifiers.contains(where: { $0.name.text == "static" || $0.name.text == "class" }) {
            continue
        }
        // Skip private/fileprivate
        if funcDecl.modifiers.contains(where: { $0.name.text == "private" || $0.name.text == "fileprivate" }) {
            continue
        }

        let name = funcDecl.name.text

        // Skip init/deinit (init won't appear as FunctionDeclSyntax, but just in case)
        if name == "init" || name == "deinit" { continue }

        // Extract params — support all label forms:
        //   func foo(label: Type)           → label="label", internalName="label"
        //   func foo(label name: Type)      → label="label", internalName="name"
        //   func foo(_ name: Type)          → label="_",     internalName="name"
        var params: [(label: String, internalName: String, jsonKey: String, type: String)] = []
        var allSupported = true

        for param in funcDecl.signature.parameterClause.parameters {
            let firstName = param.firstName.text
            let secondName = param.secondName?.text

            let label: String
            let internalName: String
            let jsonKey: String

            if firstName == "_" {
                // func foo(_ name: Type) — unlabeled param, skip method
                allSupported = false
                break
            } else if let second = secondName {
                // func foo(label name: Type) — different label and param name
                label = firstName
                internalName = second
                jsonKey = firstName
            } else {
                // func foo(label: Type) — label is also param name
                label = firstName
                internalName = firstName
                jsonKey = firstName
            }

            guard let typeStr = paramTypeString(param.type) else {
                allSupported = false
                break
            }

            params.append((label: label, internalName: internalName, jsonKey: jsonKey, type: typeStr))
        }

        if !allSupported { continue }

        let returnType = funcDecl.signature.returnClause?.type.trimmedDescription

        results.append(MethodInfo(name: name, params: params, returnType: returnType))
    }

    return results
}

func paramTypeString(_ type: TypeSyntax) -> String? {
    return type.trimmedDescription
}

// MARK: - CodeBuilder

class CodeBuilder {
    private var lines: [String] = []
    private var level = 0
    private let tab = "    "

    func line(_ text: String = "") {
        if text.isEmpty {
            lines.append("")
        } else {
            lines.append(String(repeating: tab, count: level) + text)
        }
    }

    func indented(_ body: () -> Void) {
        level += 1
        body()
        level -= 1
    }

    func build() -> String {
        lines.joined(separator: "\n")
    }
}

// MARK: - Code Generation

func generateAgentGet(properties: [PropertyInfo]) -> String {
    let b = CodeBuilder()

    for prop in properties {
        switch prop.category {
        case .primitive, .optionalPrimitive:
            b.line("case \"\(prop.name)\": return .value(\(prop.name))")

        case .array(let elementType):
            if primitiveTypes.contains(elementType) {
                b.line("case \"\(prop.name)\":")
                b.indented {
                    b.line("guard let tail else { return .value(\(prop.name)) }")
                    b.line("let (indexStr, rest) = TapPath.split(tail)")
                    b.line("guard let index = Int(indexStr), index >= 0, index < \(prop.name).count else {")
                    b.indented {
                        b.line("return .error(\"index out of bounds: \\(indexStr) (count: \\(\(prop.name).count))\")")
                    }
                    b.line("}")
                    b.line("guard rest == nil else { return .error(\"cannot traverse into primitive array element\") }")
                    b.line("return .value(\(prop.name)[index])")
                }
            } else {
                b.line("case \"\(prop.name)\":")
                b.indented {
                    b.line("guard let tail else {")
                    b.indented {
                        b.line("return .value(\(prop.name).compactMap { ($0 as? TapDispatchable)?.__tapSnapshot() })")
                    }
                    b.line("}")
                    b.line("let (indexStr, rest) = TapPath.split(tail)")
                    b.line("guard let index = Int(indexStr), index >= 0, index < \(prop.name).count else {")
                    b.indented {
                        b.line("return .error(\"index out of bounds: \\(indexStr) (count: \\(\(prop.name).count))\")")
                    }
                    b.line("}")
                    b.line("guard let rest else {")
                    b.indented {
                        b.line("return .value((\(prop.name)[index] as? TapDispatchable)?.__tapSnapshot())")
                    }
                    b.line("}")
                    b.line("return (\(prop.name)[index] as? TapDispatchable)?.__tapGet(rest) ?? .error(\"not dispatchable: \(prop.name)[]\")")
                }
            }

        case .childState:
            b.line("case \"\(prop.name)\":")
            b.indented {
                b.line("guard let tail else {")
                b.indented {
                    b.line("return .value((\(prop.name) as? TapDispatchable)?.__tapSnapshot())")
                }
                b.line("}")
                b.line("return (\(prop.name) as? TapDispatchable)?.__tapGet(tail) ?? .error(\"not dispatchable: \(prop.name)\")")
            }

        case .unsupported:
            continue
        }
    }

    return b.build()
}

func generateAgentSet(properties: [PropertyInfo]) -> String {
    let b = CodeBuilder()

    for prop in properties {
        if prop.isReadOnly { continue }

        switch prop.category {
        case .primitive(let typeName):
            let cast = castExpression(for: typeName, from: "value")
            b.line("case \"\(prop.name)\":")
            b.indented {
                b.line("guard let v = \(cast) else { return .error(\"type mismatch: \(prop.name) expects \(typeName)\") }")
                b.line("\(prop.name) = v")
                b.line("return .value(nil)")
            }

        case .optionalPrimitive(let typeName):
            let cast = castExpression(for: typeName, from: "value")
            b.line("case \"\(prop.name)\":")
            b.indented {
                b.line("if value == nil || value is NSNull { \(prop.name) = nil; return .value(nil) }")
                b.line("guard let v = \(cast) else { return .error(\"type mismatch: \(prop.name) expects \(typeName)?\") }")
                b.line("\(prop.name) = v")
                b.line("return .value(nil)")
            }

        case .array:
            b.line("case \"\(prop.name)\":")
            b.indented {
                b.line("guard let tail else { return .error(\"cannot replace \(prop.name) array directly\") }")
                b.line("let (indexStr, rest) = TapPath.split(tail)")
                b.line("guard let index = Int(indexStr), index >= 0, index < \(prop.name).count else {")
                b.indented {
                    b.line("return .error(\"index out of bounds: \\(indexStr)\")")
                }
                b.line("}")
                b.line("guard let rest else { return .error(\"cannot replace array element directly\") }")
                b.line("return (\(prop.name)[index] as? TapDispatchable)?.__tapSet(rest, value: value) ?? .error(\"not dispatchable: \(prop.name)[]\")")
            }

        case .childState:
            b.line("case \"\(prop.name)\":")
            b.indented {
                b.line("guard let tail else { return .error(\"cannot replace \(prop.name) object\") }")
                b.line("return (\(prop.name) as? TapDispatchable)?.__tapSet(tail, value: value) ?? .error(\"not dispatchable: \(prop.name)\")")
            }

        case .unsupported:
            continue
        }
    }

    return b.build()
}

func generateAgentCall(methods: [MethodInfo]) -> String {
    let b = CodeBuilder()

    for method in methods {
        b.line("case \"\(method.name)\":")
        b.indented {
            for param in method.params {
                let varName = param.internalName
                if primitiveTypes.contains(param.type) {
                    let cast = castExpression(for: param.type, from: "params[\"\(param.jsonKey)\"]")
                    b.line("guard let \(varName) = \(cast) else { return .error(\"missing param: \(param.jsonKey) (\(param.type))\") }")
                } else {
                    b.line("guard let \(varName)Raw = params[\"\(param.jsonKey)\"], let \(varName): \(param.type) = __tapDecode(\(varName)Raw) else { return .error(\"cannot decode param: \(param.jsonKey) (\(param.type))\") }")
                }
            }

            let args = method.params.map { param in
                if param.label == "_" {
                    return param.internalName
                }
                return "\(param.label): \(param.internalName)"
            }.joined(separator: ", ")

            if let returnType = method.returnType {
                b.line("let result = \(method.name)(\(args))")
                if isPrimitiveOrDict(returnType) {
                    b.line("return .value(result)")
                } else {
                    b.line("return .value(__tapEncode(result))")
                }
            } else {
                b.line("\(method.name)(\(args))")
                b.line("return .value(nil)")
            }
        }
    }

    return b.build()
}

func generateAgentSnapshot(properties: [PropertyInfo]) -> String {
    let b = CodeBuilder()

    for prop in properties {
        switch prop.category {
        case .primitive, .optionalPrimitive:
            b.line("\"\(prop.name)\": \(prop.name) as Any,")
        case .array(let elementType):
            if primitiveTypes.contains(elementType) {
                b.line("\"\(prop.name)\": \(prop.name),")
            } else {
                b.line("\"\(prop.name)\": \(prop.name).compactMap { ($0 as? TapDispatchable)?.__tapSnapshot() },")
            }
        case .childState:
            b.line("\"\(prop.name)\": (\(prop.name) as? TapDispatchable)?.__tapSnapshot() as Any,")
        case .unsupported:
            continue
        }
    }

    return b.build()
}

func isPrimitiveOrDict(_ typeStr: String) -> Bool {
    let base = typeStr.hasSuffix("?") ? String(typeStr.dropLast()) : typeStr
    return primitiveTypes.contains(base) || base == "[String: Any]"
}

func castExpression(for typeName: String, from source: String) -> String {
    switch typeName {
    case "String":
        return "\(source) as? String"
    case "Int":
        return "(\(source) as? NSNumber)?.intValue"
    case "Double":
        return "(\(source) as? NSNumber)?.doubleValue"
    case "Bool":
        return "(\(source) as? NSNumber)?.boolValue"
    default:
        return "\(source) as? \(typeName)"
    }
}
