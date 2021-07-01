## How to use this repository
### Template

When creating a new repository make sure to select this repository as a repository template.

### Customize the repository

Enter your repository specific configuration
- Replace the "Package.swift", "Sources" and "Tests" folder with your own Swift Package
- Enter your project name instead of "ApodiniTemplate" in .jazzy.yml
- Enter the correct test bundle name in the build-and-test.yml file under the "Convert coverage report" step. Most of the time the name is the name of the Project + "PackageTests".
- Update the README with your information and replace the links to the license with the new repository.
- If you create a new repository in the Apodini organzation you do not need to add a personal access token named "ACCESS_TOKEN". If you create the repo outside of the Apodini organization you need to create such a token with write access to the repo for all GitHub Actions to work.

### ⬆️ Remove everything up to here ⬆️

# Project Name

## Requirements

## Installation/Setup/Integration

## Usage

## Contributing
Contributions to this projects are welcome. Please make sure to read the [contribution guidelines](https://github.com/Apodini/.github/blob/release/CONTRIBUTING.md) first.

## License
This project is licensed under the MIT License. See [License](https://github.com/Apodini/Template-Repository/blob/release/LICENSE) for more information.
