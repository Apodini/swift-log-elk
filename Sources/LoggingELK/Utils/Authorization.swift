//
//  Authentication.swift
//  
//
//  Created by Oleg Bragin on 09.11.2022.
//

import Foundation

/// Describes the property which should be used to set the authorization header
/// to access a remote resource
public protocol Authorizable {
    /// Should return authorization header value.
    var value: String { get }
}

/// Defines the most commonly used authroization type names: Basic and Bearer
/// Basically define the first part of overall Authorization header value, e.g.:
/// `Basic <token>`, etc.
public enum AuthorizationType: String {
    case basic
    case bearer
    
    public var name: String {
        switch self {
        case .basic:
            return "Basic"
        case .bearer:
            return "Bearer"
        }
    }
}

/// Defines the default way of providing the authorization header to caller
public struct Authorization: Authorizable {
    /// Type of authorization
    let type: AuthorizationType
    /// Token string, which should generated outside
    let token: String
    
    /// A string concatenated from type name and token itself for authroization header field
    public var value: String {
        return "\(type.name) \(token)"
    }
}
