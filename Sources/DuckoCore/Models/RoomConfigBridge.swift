import DuckoXMPP

public extension RoomConfigField {
    /// Initializes from a ``DataFormField`` returned by MUCModule.
    init(from field: DataFormField) {
        self.init(
            variable: field.variable,
            type: field.type,
            label: field.label,
            values: field.values,
            options: field.options.map { (label: $0.label, value: $0.value) }
        )
    }

    /// Converts back to a ``DataFormField`` for submission.
    func toDataFormField() -> DataFormField {
        DataFormField(
            variable: variable,
            type: type,
            label: label,
            values: values,
            options: options.map { (label: $0.label, value: $0.value) }
        )
    }
}
