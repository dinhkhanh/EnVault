/// Team vaults are built but not launched: on in debug builds, off in
/// release builds until the beta (plan phase 6). One switch for the UI, the
/// share-link handler and opening team vaults after unlock.
enum TeamFeatures {
    static var enabled: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
