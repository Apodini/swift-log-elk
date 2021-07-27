# LoggingELK

![Swift5.4+](https://img.shields.io/badge/Swift-5.4%2B-orange.svg?style=flat)
[![release](https://img.shields.io/github/v/release/Apodini/swift-log-elk.svg?include_prereleases&color=blue)](https://github.com/Apodini/swift-log-elk/releases)
[![codecov](https://codecov.io/gh/Apodini/swift-log-elk/branch/develop/graph/badge.svg?token=M9a8FsTExH)](https://codecov.io/gh/Apodini/swift-log-elk)
[![jazzy](https://raw.githubusercontent.com/Apodini/swift-log-elk/gh-pages/badge.svg)](https://apodini.github.io/swift-log-elk/)
[![Build and Test](https://github.com/Apodini/swift-log-elk/actions/workflows/build-and-test.yml/badge.svg)](https://github.com/Apodini/swift-log-elk/actions/workflows/build-and-test.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/Apodini/swift-log-elk/blob/master/LICENSE)

### **LoggingELK is a logging backend library for Apple's swift-log**

The LoggingELK library provides a logging backend for Apple's [apple/swift-log](https://github.com/apple/swift-log/) package (which basically just defines a logging API). The log entries are properly formatted, cached, and then uploaded via HTTP/HTTPS to [elastic/logstash](https://github.com/elastic/logstash), which allows for further processing in its pipeline. The logs can then be stored in [elastic/elasticsearch](https://github.com/elastic/elasticsearch) and visualized in [elastic/kibana](https://github.com/elastic/kibana).

## Features
- Written completly in Swift
- Supports both Darwin (macOS) and Linux platforms
- Uploads the log data automatically to Logstash (eg. the ELK stack)
- Caches the created log entries and sends them via HTTP either periodically or when exceeding a certain configurable memory threshold to Logstash
- Converts the logging metadata to a JSON representation, which allows querying after those values (eg. filter after a specific parameter in Kibana)
- Logs itself via a background activity logger (including protection against a possible infinite recursion)

## Setup

LoggingELK requires Xcode 12 or a Swift 5.4 toolchain with the Swift Package Manager. 

### Swift Package Manager

Add `swift-log` and the `swift-log-elk` package as a dependency to your `Package.swift` file.

```swift
dependencies: [
    .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    .package(url: "https://github.com/Apodini/swift-log-elk.git", from: "0.1.0")
]
```

Add `Logging` (from `swift-log`) and `LoggingELK` (from `swift-log-elk`) to your target's dependencies.

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

Import both `Logging` and `LoggingELK` modules:

```swift
import Logging
import LoggingELK
```

Create the `LogstashLogHandler` with the appropriate configuration and register the to be used logging backend once (!) during the lifetime of the application:

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

**Important:** The `maximumTotalLogStorageSize` MUST be at least twice as large as the `logStorageSize` (this is also validated during instanciation of the `LogstashLogHandler`). The reason for this are the temporary buffers that are allocated during uploading of the log data, so that a simultaneous logging call doesn't block (except for the duration it takes to copy the logs to the temporary buffer which is very fast). 

Why at least twice as large? The process of allocating temporary buffers could possibly be repeated, if the log storage runs full during uploading of "old" log data. A possible scenario is an environment, where the network conncection to Logstash is really slow and therefore the uploading takes long. This process could repeat itself over and over again until the `maximumTotalLogStorageSize` is reached. Then, a new logging call blocks until enought memory space is available again, achieved through a partial completed uploading of log data, resulting in freed temporary buffers. In practice, approaching the `maximumTotalLogStorageSize` should basically never happen, except in very resource restricted environments.

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
        logStorageSize: 524_288,    // 512kB
        maximumTotalLogStorageSize: 2_097_152       // 2MB
    )
}
```

Now that the setup of the `LogstashLogHandler` is completed, you can use `SwiftLog` as usual (also with metadata etc.). 

```swift
import Logging

let logger = Logger(label: "com.example.WebService")

logger.info("This is a test!")
```

### Setup Logstash (ELK stack)

To actually use the `LogstashLogHandler`, there's obviously one last step left: Set up a [elastic/logstash](https://github.com/elastic/logstash) instance where the logs are sent to. 
The probably most easy setup of a local Logstash instance is to use [docker/elk](https://github.com/deviantony/docker-elk), which provides the entire Elastic stack (ELK) powered by [Docker](https://www.docker.com/) and [Docker-compose](https://docs.docker.com/compose/). The ELK stack allows us to collect, analyze and present the log data and much much more. Please follow the instructions in the [README.me](https://github.com/deviantony/docker-elk#readme) of the repository to setup and configure the ELK stack correctly.

Then, we need to configure the Logstash pipeline to accept HTTP input on a certain host and port. This can be done in the [Logstash pipeline configuration file](https://github.com/deviantony/docker-elk/blob/main/logstash/pipeline/logstash.conf). 
Just adapt the `input` section of the file like this to allow logs to be uploaded locally on port 31311:

```
input {
    http {
        host => "0.0.0.0"
        port => 31311
    }
}
```

Furthermore, to use the timestamp created by the `LogstashLogHandler` (not the timestamp when the data is actually sent to Logstash), adapt the `filter` section of the [Logstash pipeline configuration file](https://github.com/deviantony/docker-elk/blob/main/logstash/pipeline/logstash.conf) like shown below. The second option eliminates the headers of the HTTP request from the `LogstashLogHandler` to Logstash, since those headers would also have been saved to the log entry (which are definitly not relevant to us).

```
filter {
    date {
        match => [ "timestamp", "ISO8601" ]
        locale => "en_US"       # POSIX
        target => "@timestamp"
    }

    mutate {
        remove_field => ["headers"]
    }
}
```

Now that the entire setup process is finished, create some log data that is then automatically sent to Logstash (eg. see [section above](#setup-logging)). 

Since we use the entire ELK stack, not just Logstash, we can use [elastic/kibana](https://github.com/elastic/kibana) to instantly visualize the uploaded log data. Access the Kibana web interface (on the respective port) and navigate to `Analytics/Discover`. Your created log messages (including metadata) should now be displayed here:

![image](https://user-images.githubusercontent.com/25406915/127134981-45e0ce7f-9718-4550-a0b1-e1138e8035e4.png)

Congrats, you sent your first logs via swift-log and swift-log-elk to [elastic/logstash](https://github.com/elastic/logstash), saved them in  [elastic/elasticsearch](https://github.com/elastic/elasticsearch) and visualized them with [elastic/kibana](https://github.com/elastic/kibana)! 🎉

## Usage

For details on how to use the Logging features of [apple/swift-log](https://github.com/apple/swift-log/) exactly, please check out the [documentation of swift-log](https://github.com/apple/swift-log#readme).

## Documentation

Take a look at our [API reference](https://apodini.github.io/swift-log-elk/) for a full documentation of the package.

## Contributing
Contributions to this project are welcome. Please make sure to read the [contribution guidelines](https://github.com/Apodini/.github/blob/release/CONTRIBUTING.md) first.

## License
This project is licensed under the MIT License. See [License](https://github.com/Apodini/swift-log-elk/blob/release/LICENSE) for more information.
