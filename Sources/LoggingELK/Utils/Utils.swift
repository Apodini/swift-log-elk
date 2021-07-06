//
//  Utils.swift
//  
//
//  Created by Philipp Zagar on 01.07.21.
//


/// The `Box` type can be used to wrap an object in a class
public class Box<T> {
    /// The value stored by the `Box`
    public var value: T
    
    /// Creates a new box filled with the specified value, and,
    /// if `T` has reference semantics, establishing a strong reference to it.
    public init(_ value: T) {
        self.value = value
    }
}
