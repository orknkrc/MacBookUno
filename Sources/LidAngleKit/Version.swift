/// The single source of truth for the project version.
///
/// Both executables print it via `--version`, and `Scripts/make-app.sh` reads it
/// straight out of this file to fill in the bundle's Info.plist, so the binary
/// and the bundle can never disagree.
///
/// Semantic versioning: MAJOR.MINOR.PATCH.
///  - MAJOR: incompatible change in behavior or in the LidAngleKit API
///  - MINOR: new functionality, backwards compatible
///  - PATCH: bug fixes only
public enum ProjectVersion {
    public static let current = "0.2.0"
}
