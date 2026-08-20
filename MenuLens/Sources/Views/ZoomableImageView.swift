import SwiftUI
import UIKit

/// Pinch-zoomable, pannable image canvas with double-tap zoom and a
/// single-tap callback reporting the tapped point in normalized image
/// coordinates (0...1, top-left origin).
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    var onTap: ((CGPoint) -> Void)?

    func makeUIView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView(image: image)
        view.onTapNormalized = onTap
        return view
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        view.onTapNormalized = onTap
        if view.imageView.image !== image {
            view.setImage(image)
        }
    }
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var onTapNormalized: ((CGPoint) -> Void)?
    /// Set on init / image-size change only — the user's zoom must survive
    /// re-layouts (bottom bars appearing, highlight re-renders, rotations).
    private var needsInitialLayout = true

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        bouncesZoom = true
        backgroundColor = .clear
        imageView.image = image
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.require(toFail: doubleTap)
        imageView.addGestureRecognizer(doubleTap)
        imageView.addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setImage(_ image: UIImage) {
        // Same-size swaps (e.g. order highlights re-rendered) keep the
        // user's zoom and scroll position; only a size change refits.
        let sameSize = imageView.image?.size == image.size
        imageView.image = image
        if !sameSize {
            needsInitialLayout = true
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = imageView.image, bounds.width > 0, bounds.height > 0 else { return }
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        if needsInitialLayout {
            needsInitialLayout = false
            imageView.frame = CGRect(origin: .zero, size: image.size)
            contentSize = image.size
            minimumZoomScale = fit
            maximumZoomScale = max(fit * 6, 2)
            zoomScale = fit
        } else {
            // Keep the current zoom; just track the new fit as the floor.
            minimumZoomScale = fit
            maximumZoomScale = max(fit * 6, 2)
            if zoomScale < fit { zoomScale = fit }
        }
        centerContent()
    }

    private func centerContent() {
        let dx = max((bounds.width - contentSize.width) / 2, 0)
        let dy = max((bounds.height - contentSize.height) / 2, 0)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard imageView.bounds.width > 0, imageView.bounds.height > 0 else { return }
        let point = gesture.location(in: imageView)
        onTapNormalized?(CGPoint(
            x: point.x / imageView.bounds.width,
            y: point.y / imageView.bounds.height
        ))
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale * 1.15 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let center = gesture.location(in: imageView)
            let size = CGSize(width: bounds.width / 2.5, height: bounds.height / 2.5)
            zoom(to: CGRect(
                x: center.x - size.width / 2, y: center.y - size.height / 2,
                width: size.width, height: size.height
            ), animated: true)
        }
    }
}
