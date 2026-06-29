extension ResolvedMachine {
    /// Exports this machine as an XState-compatible JSON definition string.
    public func definitionJSON() throws -> String {
        try MachineDefinitionExporter.export(self)
    }
}
