import Foundation

@main
enum MessageImageFitValidation {
    static func main() {
        expect(MessageImageFit.single(width: 800, height: 400), width: 240, height: 120, crop: .center)
        expect(MessageImageFit.single(width: 100, height: 1000), width: 60, height: 240, crop: .top)
        expect(MessageImageFit.single(width: 1000, height: 100), width: 240, height: 60, crop: .leading)
        expect(MessageImageFit.single(width: 32, height: 16), width: 32, height: 16, crop: .center)
        print("MessageImageFitValidation: 4 fixtures passed")
    }

    private static func expect(_ fit: MessageImageFit, width: CGFloat, height: CGFloat, crop: MessageImageFit.Crop) {
        precondition(fit.width == width && fit.height == height && fit.crop == crop)
    }
}
