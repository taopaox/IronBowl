import Foundation
import IronBowlKit
import Testing

@Test
func appVersionFormatsStandardAndPrefixedStrings() {
    let standard = AppVersionInfo.from(infoDictionary: [
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "12",
    ])
    #expect(standard.shortVersion == "0.1.0")
    #expect(standard.buildVersion == "12")
    #expect(standard.displayVersion == "v0.1.0")
    #expect(standard.fullVersion == "v0.1.0 (12)")

    let upperPrefixed = AppVersionInfo(shortVersion: "V1.2.3", buildVersion: "")
    #expect(upperPrefixed.displayVersion == "v1.2.3")
    #expect(upperPrefixed.fullVersion == "v1.2.3")

    let lowerPrefixed = AppVersionInfo(shortVersion: "v2.0.0", buildVersion: "5")
    #expect(lowerPrefixed.displayVersion == "v2.0.0")
    #expect(lowerPrefixed.fullVersion == "v2.0.0 (5)")
}

@Test
func appVersionHandlesMissingOrBlankInfoDictionary() {
    let empty = AppVersionInfo.from(infoDictionary: nil)
    #expect(empty.shortVersion.isEmpty)
    #expect(empty.buildVersion.isEmpty)
    #expect(empty.displayVersion == "v0.0.0")
    #expect(empty.fullVersion == "v0.0.0")

    let whitespace = AppVersionInfo(shortVersion: "  0.2.0 \n", buildVersion: "  ")
    #expect(whitespace.displayVersion == "v0.2.0")
    #expect(whitespace.fullVersion == "v0.2.0")
}

@Test
func appBrandExposesOfficialSloganAndAboutCredits() {
    #expect(AppBrand.name == "饭碗")
    #expect(AppBrand.englishName == "IronBowl")
    #expect(AppBrand.slogan == "先把饭碗端稳，再慢慢加菜，不烧心。")
    #expect(AppBrand.aboutCredits().string.contains(AppBrand.slogan))
}
