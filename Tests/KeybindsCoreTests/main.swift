import Foundation

optionTapDetectorTests()
modifierEventTranslatorTests()
settingsTests()

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
