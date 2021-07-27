# swift-log-elk

![Swift5.4+](https://img.shields.io/badge/Swift-5.4%2B-orange.svg?style=flat)
[![release](https://img.shields.io/github/v/release/Apodini/swift-log-elk.svg?include_prereleases&color=blue)](https://github.com/Apodini/swift-log-elk/releases)
[![codecov](https://codecov.io/gh/Apodini/swift-log-elk/branch/develop/graph/badge.svg?token=M9a8FsTExH)](https://codecov.io/gh/Apodini/swift-log-elk)
[![jazzy](https://raw.githubusercontent.com/Apodini/swift-log-elk/gh-pages/badge.svg)](https://apodini.github.io/swift-log-elk/)
[![Build and Test](https://github.com/Apodini/swift-log-elk/actions/workflows/build-and-test.yml/badge.svg)](https://github.com/Apodini/swift-log-elk/actions/workflows/build-and-test.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/Apodini/swift-log-elk/blob/master/LICENSE)

### **swift-log-elk is a logging backend library for Apple's swift-log**

The swift-log-elk library provides a logging backend for Apple's [apple/swift-log](https://github.com/apple/swift-log/) package (which basically just defines a logging API). The log entries are properly formatted, cached, and then uploaded via HTTP/HTTPS to [elastic/logstash](https://github.com/elastic/logstash), which allows for further processing in its pipeline. The logs can then be stored in ElasticSearch [elastic/elasticsearch](https://github.com/elastic/elasticsearch) and visualized in [elastic/kibana](https://github.com/elastic/kibana).

## Features
- Written completly in Swift
- Supports both Darwin (macOS) and Linux platforms
- Uploads the log data automatically to Logstash (eg. the ELK stack)
- Caches the created log entries and sends them via HTTP either periodically or when exceeding a certain configurable memory threshold to Logstash
- Converts the logging metadata to a JSON representation, which allows querying after those values (eg. filter after a specific parameter in Kibana)
- Logs itself via a background activity logger (including protection against a possible infinte recursion)

## Setup

LoggingELK requires Xcode 12 or a Swift 5.4 toolchain with the Swift Package Manager. 

### Swift Package Manager

Add swift-log and the swift-log-elk package as a dependency to your `Package.swift` file.

```swift
dependencies: [
    .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    .package(url: "https://github.com/Apodini/swift-log-elk.git", from: "0.1.0")
]
```

Add Logging and LoggingELK to your target's dependencies.

```swift
targets: [
    .target(
        name: "ExampleWebService",
        dependencies: [
            .product(name: "Logging", package: "swift-log"),
            .product(name: "LoggingELK", package: "swift-log-elk")
        ]
    )
]
```

### Setup Logging

Import both `Logging` (from swift-log) and `LoggingELK` (from swift-log-elk) modules:

```swift
import Logging
import LoggingELK
```

Create the to be used `LogstashLogHandler` with the appropriate configuration and register the to be used logging backend once (!) during the lifetime of the application:

```swift
LoggingSystem.bootstrap { label in
    LogstashLogHandler(
        label: label,
        hostname: "0.0.0.0",
        port: 31311
    )
}
```

Furthermore, it's possible to register multiple logging backends. An option would be to send the logs to Logstash as well as print them to console:

```swift
LoggingSystem.bootstrap { label in
    MultiplexLogHandler(
        [
            LogstashLogHandler(
                label: label,
                hostname: "0.0.0.0",
                port: 31311
            ),
            StreamLogHandler.standardOutput(label: label)
        ]
    ) 
}
```

The `LogstashLogHandler` can also be configured beyond the standard configuration values. Below you can see an example of the maximum possible configuration options. The developer can eg. specify if HTTPS (so TLS encryption) should be used, the to be used `EventLoopGroup` for handeling the HTTP requests, a `Logger` that logs background activity of the `LogstashLogHandler` or network connectivity, and a certain `uploadInterval`, so in what time intervals the log data should be uploaded to Logstash. Furthermore, the size of the buffer that caches the log data can be configured as well as the maximum total size of all the log buffers (since temporary buffers are created during uploading).

```swift
LoggingSystem.bootstrap { label in
    LogstashLogHandler(
        label: "logstash",
        hostname: "0.0.0.0",
        port: 31311,
        useHTTPS: false,
        eventLoopGroup: eventLoopGroup,
        backgroundActivityLogger: logger,
        uploadInterval: TimeAmount.seconds(3),
        logStorageSize: 524_288,
        maximumTotalLogStorageSize: 2_097_152
    )
}
```

Now that the setup of the `LogstashLogHandler` is completed, you can use `SwiftLog` as usual (also with metadata etc.). 

```swift
import Logging

let logger = Logger(label: "com.example.WebService")

logger.info("This is a test!")
```

![image](https://user-images.githubusercontent.com/25406915/127134981-45e0ce7f-9718-4550-a0b1-e1138e8035e4.png)


ELK stack must be running (or only Logstash). I recommend the docker-elk package (link), since it provides all the tools necessary to collect, analyze and present the log data. Show pipeline config for http and resulting kibana screen with 2-3 logs

## Documentation

Take a look at our [API reference](https://apodini.github.io/swift-log-elk/) for a full documentation of the package.

## Usage

## Contributing
Contributions to this project are welcome. Please make sure to read the [contribution guidelines](https://github.com/Apodini/.github/blob/release/CONTRIBUTING.md) first.

## License
This project is licensed under the MIT License. See [License](https://github.com/Apodini/swift-log-elk/blob/release/LICENSE) for more information.
