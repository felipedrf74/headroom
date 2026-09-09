import AppKit

enum HeadroomImage {
    static func named(_ name: String, template: Bool = false, bundle: Bundle = .main) -> NSImage? {
        if let image = fromBundle(name, bundle: bundle) {
            image.isTemplate = template
            return image
        }
        if bundle == .main, let image = NSImage(named: name), image.isValid, !image.representations.isEmpty {
            image.isTemplate = template
            return image
        }
        return nil
    }

    static func template(_ name: String, bundle: Bundle = .main) -> NSImage? {
        named(name, template: true, bundle: bundle)
    }

    private static func fromBundle(_ name: String, bundle: Bundle) -> NSImage? {
        let image = NSImage()
        let variants: [(String, CGFloat)] = [(name, 1), ("\(name)@2x", 2), ("\(name)@3x", 3)]
        var found = false
        for (resource, scale) in variants {
            guard let url = bundle.url(forResource: resource, withExtension: "png"),
                  let rep = NSImageRep(contentsOf: url)
            else { continue }
            let size = NSSize(
                width: CGFloat(rep.pixelsWide) / scale,
                height: CGFloat(rep.pixelsHigh) / scale
            )
            rep.size = size
            image.addRepresentation(rep)
            if !found {
                image.size = size
            }
            found = true
        }
        return found ? image : nil
    }
}
