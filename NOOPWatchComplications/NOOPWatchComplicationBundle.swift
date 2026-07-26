import WidgetKit
import SwiftUI

/// The watchOS complication extension entry point. Bundles the Charge and HRV complications so the
/// watch face can place either in any of the supported accessory families. The watch app (the glance
/// UI) lives in a separate target; this extension only draws the face complications.
@main
struct NOOPWatchComplicationBundle: WidgetBundle {
    var body: some Widget {
        NOOPChargeComplication()
        NOOPSleepComplication()
        NOOPStrainComplication()
        NOOPHRVComplication()
    }
}
