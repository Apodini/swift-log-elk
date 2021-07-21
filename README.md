# swift-log-elk

![Swift5.0+](https://img.shields.io/badge/Swift-5.0%2B-orange.svg?style=flat)
[![release](https://img.shields.io/github/v/release/Apodini/swift-log-elk.svg?include_prereleases&color=blue)](https://github.com/Apodini/swift-log-elk/releases)
[![codecov](https://codecov.io/gh/Apodini/swift-log-elk/branch/develop/graph/badge.svg?token=M9a8FsTExH)](https://codecov.io/gh/Apodini/swift-log-elk)
[![jazzy](https://raw.githubusercontent.com/Apodini/swift-log-elk/gh-pages/badge.svg)](https://apodini.github.io/swift-log-elk/)
[![Build and Test](https://github.com/Apodini/swift-log-elk/actions/workflows/build-and-test.yml/badge.svg)](https://github.com/Apodini/swift-log-elk/actions/workflows/build-and-test.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/Apodini/swift-log-elk/blob/master/LICENSE)

### **swift-log-elk is a logging backend library for Apple's swift-log**

The swift-log-elk library provides a logging backend for Apple's [apple/swift-log](https://github.com/apple/swift-log/) package (which basically just defines a logging API). The log entries are properly formatted, cached, and then uploaded via HTTP to [elastic/logstash](https://github.com/elastic/logstash), which allows for further processing in its pipeline. The logs can then be stored in ElasticSearch [elastic/elasticsearch](https://github.com/elastic/elasticsearch) and visualized in [elastic/kibana](https://github.com/elastic/kibana).

## Features
- Written completly in Swift
- Supports both Darwin (macOS) and Linux platforms
- Uploads the log data automatically to Logstash (eg. the ELK stack)
- Caches the created log entries and sends them via HTTP either periodically or when exceeding a certain configurable memory threshold to Logstash
- Converts the logging metadata to a JSON representation, which allows querying after those values (eg. filter after a specific parameter in Kibana)
- Logs itself via a background activity logger

## Requirements

## Installation/Setup/Integration

## Usage

## Contributing
Contributions to this project are welcome. Please make sure to read the [contribution guidelines](https://github.com/Apodini/.github/blob/release/CONTRIBUTING.md) first.

## License
This project is licensed under the MIT License. See [License](https://github.com/Apodini/swift-log-elk/blob/release/LICENSE) for more information.
