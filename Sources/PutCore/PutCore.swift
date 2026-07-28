import Foundation

/// Current config schema version. Bumped whenever `Config` gains incompatible fields.
///
/// History:
/// - 1: initial.
/// - 2: layouts gained an optional `screenConfig` trigger. Decoding is
///   backwards-compatible (the field is optional and tolerant), so the bump
///   exists primarily as a forensics marker for debugging older files.
/// - 3: layouts now carry `screenConfigs` (an array) instead of a single
///   `screenConfig`. The Layout decoder maps the legacy single value into the
///   array, so reads are backwards-compatible; the bump matters because a v3
///   document writes only `screenConfigs`, which a v2-era app would silently
///   ignore — `ConfigStore` rejects schema versions above what it supports.
public let putSchemaVersion = 3
