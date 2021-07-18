//
//  Boxed.swift
//
//
//  Created by Philipp Zagar on 01.07.21.
//

/// The `Boxed` property wrapper can be used to wrap an object in a class
@propertyWrapper
public class Boxed<T> {
    /// The value stored by the `Boxed` property wrapper
    public var wrappedValue: T

    /// Initializor of the property warpper
    public init(wrappedValue: T) {
        self.wrappedValue = wrappedValue
    }
}
