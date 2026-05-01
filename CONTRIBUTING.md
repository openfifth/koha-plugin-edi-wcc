# Contributing to koha-plugin-wcc-sap

Thank you for your interest in contributing to the WCC SAP Finance Integration plugin! This document provides guidelines for developers who want to contribute to the project.

> 📖 **New to this project?** Start with the [main README](README.md) for an overview of the plugin's features and usage.

## Development Setup

### Prerequisites

- Koha development environment
- Node.js (for build tools and version management)
- Git
- Perl with required Koha modules

### Getting Started

1. Fork the repository
2. Clone your fork:
   ```bash
   git clone https://github.com/YOUR-USERNAME/koha-plugin-wcc-sap.git
   cd koha-plugin-wcc-sap
   ```
3. Install dependencies:
   ```bash
   npm install
   ```

## Development Workflow

### Making Changes

1. Create a feature branch:
   ```bash
   git checkout -b feature/your-feature-name
   ```
2. Make your changes
3. Run tests to ensure everything works:
   ```bash
   prove t/
   ```
4. Commit your changes with descriptive messages

### Testing

We use Perl's standard testing framework. Tests are located in the `t/` directory.

#### Running Tests
```bash
prove t/                # Run all tests
prove t/00-load.t      # Run specific test
```

#### Adding Tests

When adding new functionality:

1. Create a test file in the `t/` directory
2. Use descriptive filenames (e.g., `10-report-generation.t`)
3. Follow standard Perl testing practices
4. Test both success and error conditions

### Code Style

- Follow Modern Perl practices
- Use meaningful variable and function names
- Add comments for complex logic
- Follow existing code patterns in the plugin

## Release Process

This project uses automated releases with semantic versioning.

### Making a Release

**Option 1: Automated Semantic Versioning (Recommended)**
```bash
npm run release:patch    # For bug fixes (0.0.7 → 0.0.8)
npm run release:minor    # For new features (0.0.7 → 0.1.0)
npm run release:major    # For breaking changes (0.0.7 → 1.0.0)
```

**Option 2: Manual Process**
1. Update version in `Koha/Plugin/Com/OpenFifth/SAP.pm`
2. Update version in `package.json` to match
3. Create git tag and push to trigger automated release

### What Happens During Release

The automated process:
1. Updates version numbers
2. Creates a .kpz plugin file
3. Commits changes and creates a git tag
4. Pushes to GitHub
5. GitHub Actions creates a release with the .kpz file attached

## Project Structure

```
koha-plugin-wcc-sap/
├── .github/
│   └── workflows/
│       └── main.yml        # GitHub Actions workflow
├── docs/                   # Additional documentation
├── Koha/
│   └── Plugin/
│       └── Com/
│           └── OpenFifth/
│               ├── SAP.pm  # Main plugin file
│               └── SAP/    # Template files
│                   ├── configure.tt
│                   ├── report-step1.tt
│                   ├── report-step2-html.tt
│                   └── report-step2-txt.tt
├── t/                      # Test files
│   ├── 00-load.t          # Basic loading test
│   └── README.md          # Testing documentation
├── increment_version.js    # Version management utility
├── CLAUDE.md              # Claude Code guidance
├── CONTRIBUTING.md        # This file
├── package.json           # Node.js configuration
└── README.md              # Main documentation
```

## Development Commands Reference

### Version Management
```bash
npm run version:patch   # Update package.json version (patch)
npm run version:minor   # Update package.json version (minor)
npm run version:major   # Update package.json version (major)
```

### Utilities
```bash
node increment_version.js patch       # Increment patch version
node increment_version.js minor       # Increment minor version
node increment_version.js major       # Increment major version
```

### Manual Build
```bash
zip -r koha-plugin-sap.kpz Koha/     # Create .kpz file manually
```

## Contributing Guidelines

### Pull Requests

1. Ensure your code follows the project style
2. Add tests for new functionality
3. Update documentation as needed
4. Ensure all tests pass
5. Write clear commit messages
6. Reference any related issues

### Issue Reporting

When reporting issues:
- Use a clear, descriptive title
- Provide steps to reproduce
- Include relevant error messages
- Specify your Koha version
- Include plugin version

### Feature Requests

For new features:
- Explain the use case
- Describe the expected behavior
- Consider backward compatibility
- Discuss potential implementation approaches

## Code Review Process

1. All changes must be submitted via pull request
2. At least one maintainer review is required
3. All tests must pass
4. Documentation updates must be included for user-facing changes

## Getting Help

- **Issues**: [GitHub Issues](https://github.com/openfifth/koha-plugin-wcc-sap/issues)
- **Discussions**: Use GitHub Discussions for questions
- **Documentation**: Check the `docs/` directory and README.md

## License

By contributing, you agree that your contributions will be licensed under the GPL-3.0 license.