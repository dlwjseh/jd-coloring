import SwiftUI
import UIKit

extension Image {
    init?(data: Data) {
        guard let img = UIImage(data: data) else { return nil }
        self = Image(uiImage: img)
    }
}
