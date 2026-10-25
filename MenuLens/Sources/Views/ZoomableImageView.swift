import SwiftUI
import UIKit

/// Pinch-zoomable, pannable image canvas with double-tap zoom and a
/// single-tap callback reporting the tapped point in normalized image
/// coordinates (0...1, top-left origin).
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    /// Where a previous view of this image was (zoom and center), to open at.
    var place: ZoomScrollView.Place?
    /// Reports the zoom and center as the reader moves.
    var onPlaceChange: ((ZoomScrollView.Place) -> Void)?
    var onTap: ((CGPoint) -> Void)?

    func makeUIView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView(image: image)
        view.restorePlace = place
        view.onPlaceChange = onPlaceChange
        view.onTapNormalized = onTap
        return view
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        view.onPlaceChange = onPlaceChange
        view.onTapNormalized = onTap
        if view.imageView.image !== image {
            view.setImage(image)
        }
    }
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    /// The reader's place, independent of the view's size: zoom relative to
    /// fitting the whole image, and the visible center in normalized image
    /// coordinates. Survives the canvas being rebuilt at another size (the
    /// iPhone Duo folding or unfolding).
    struct Place: Equatable {
        var zoomOverFit: CGFloat
        var center: CGPoint
    }

    let imageView = UIImageView()
    var onTapNormalized: ((CGPoint) -> Void)?
    var onPlaceChange: ((Place) -> Void)?
    /// Applied once, on the first layout.
    var restorePlace: Place?
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
            if let place = restorePlace, place.zoomOverFit > 1.01 {
                zoomScale = min(fit * place.zoomOverFit, maximumZoomScale)
                centerContent()
                show(center: place.center)
            }
            restorePlace = nil
        } else if abs(minimumZoomScale - fit) > 0.0001 {
            // The view changed size (rotation, the Duo folding). Seen whole,
            // it stays whole; zoomed in, it keeps its zoom over the new fit
            // and its center.
            let place = currentPlace
            let wasFit = zoomScale <= minimumZoomScale * 1.01
            minimumZoomScale = fit
            maximumZoomScale = max(fit * 6, 2)
            if wasFit {
                zoomScale = fit
            } else {
                zoomScale = min(max(fit * place.zoomOverFit, fit), maximumZoomScale)
                centerContent()
                show(center: place.center)
            }
        }
        centerContent()
    }

    private var currentPlace: Place {
        let size = imageView.image?.size ?? .zero
        let visible = CGPoint(
            x: (contentOffset.x + bounds.width / 2) / max(zoomScale, 0.0001),
            y: (contentOffset.y + bounds.height / 2) / max(zoomScale, 0.0001)
        )
        return Place(
            zoomOverFit: zoomScale / max(minimumZoomScale, 0.0001),
            center: CGPoint(x: visible.x / max(size.width, 1), y: visible.y / max(size.height, 1))
        )
    }

    /// Scrolls so the normalized image point is in the middle (clamped).
    private func show(center: CGPoint) {
        let x = center.x * contentSize.width - bounds.width / 2
        let y = center.y * contentSize.height - bounds.height / 2
        contentOffset = CGPoint(
            x: min(max(x, -contentInset.left), max(contentSize.width + contentInset.right - bounds.width, -contentInset.left)),
            y: min(max(y, -contentInset.top), max(contentSize.height + contentInset.bottom - bounds.height, -contentInset.top))
        )
    }

    private func reportPlace() {
        guard !needsInitialLayout, bounds.width > 0 else { return }
        onPlaceChange?(currentPlace)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        reportPlace()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { reportPlace() }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { reportPlace() }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { reportPlace() }

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
