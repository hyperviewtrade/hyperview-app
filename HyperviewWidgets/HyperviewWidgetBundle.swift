import WidgetKit
import SwiftUI

@main
struct HyperviewWidgetBundle: WidgetBundle {
    var body: some Widget {
        MarketWidget()
        PositionsWidget()
    }
}
