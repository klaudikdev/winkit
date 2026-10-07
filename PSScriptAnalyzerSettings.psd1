@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The console banner and test output are meant for people.
        'PSAvoidUsingWriteHost',
        # WinKit has its own preview mode and confirmation dialogs.
        'PSUseShouldProcessForStateChangingFunctions',
        # Names such as Get-WKInstalledPackageIds describe collections on purpose.
        'PSUseSingularNouns',
        # Sources are ASCII by design; build.ps1 adds the BOM to the release file.
        'PSUseBOMForUnicodeEncodedFile',
        # WPF event handlers receive (sender, args) whether they use them or not.
        'PSReviewUnusedParameter'
    )
}
