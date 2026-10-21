import UIKit

/// The extension and the offline preview host render the same native view.
@MainActor final class ShareStatusView: UIView {
    static let surface = DropBrand.transferBackground
    private let headline = UILabel()
    private let status = UILabel()
    private let detail = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let stages = UIStackView()
    private var dots: [UIImageView] = []
    let closeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Self.surface
        overrideUserInterfaceStyle = .dark
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)

        let name = UILabel()
        name.text = "Codex Drop"
        name.font = .preferredFont(forTextStyle: .body)
        name.adjustsFontForContentSizeCategory = true
        name.textColor = DropBrand.ink
        name.accessibilityTraits = .header
        name.accessibilityIdentifier = "share.brand"
        name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(name)

        let icon = UIImageView(image: UIImage(named: "DropMark"))
        icon.contentMode = .scaleAspectFit
        icon.isAccessibilityElement = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 160), icon.heightAnchor.constraint(equalToConstant: 160)])

        headline.textAlignment = .center
        headline.numberOfLines = 0
        headline.font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: .systemFont(ofSize: 32, weight: .semibold))
        headline.adjustsFontForContentSizeCategory = true
        headline.textColor = DropBrand.ink
        headline.accessibilityTraits = .header
        headline.accessibilityIdentifier = "share.title"
        status.accessibilityIdentifier = "share.status"
        detail.accessibilityIdentifier = "share.detail"
        for label in [status, detail] {
            label.textAlignment = .center
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        status.font = .preferredFont(forTextStyle: .body)
        status.textColor = DropBrand.ink
        detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.textColor = DropBrand.secondary
        spinner.color = DropBrand.lavender
        spinner.hidesWhenStopped = true
        spinner.setContentHuggingPriority(.required, for: .horizontal)
        let statusRow = UIStackView(arrangedSubviews: [spinner, status])
        statusRow.axis = .horizontal
        statusRow.alignment = .center
        statusRow.spacing = 10

        stages.axis = .horizontal
        stages.alignment = .center
        stages.spacing = 12
        stages.isAccessibilityElement = true
        stages.accessibilityIdentifier = "share.stages"
        for index in 0..<3 {
            if index > 0 {
                let connector = UIView()
                connector.backgroundColor = UIColor(white: 0.4, alpha: 1)
                NSLayoutConstraint.activate([connector.widthAnchor.constraint(equalToConstant: 20), connector.heightAnchor.constraint(equalToConstant: 1.5)])
                stages.addArrangedSubview(connector)
            }
            let dot = UIImageView()
            dot.contentMode = .scaleAspectFit
            NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 14), dot.heightAnchor.constraint(equalToConstant: 14)])
            stages.addArrangedSubview(dot)
            dots.append(dot)
        }

        let content = UIStackView(arrangedSubviews: [icon, headline, statusRow, stages, detail])
        content.axis = .vertical
        content.alignment = .center
        content.spacing = 16
        // The supplied glowing mark includes transparent padding around its silhouette.
        content.setCustomSpacing(-6, after: icon)
        content.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        addSubview(scroll)
        scroll.addSubview(content)
        for label in [headline, detail] { label.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        statusRow.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor).isActive = true

        var button = UIButton.Configuration.filled()
        button.baseBackgroundColor = UIColor(white: 0.20, alpha: 1)
        button.baseForegroundColor = DropBrand.ink
        button.cornerStyle = .large
        button.background.cornerRadius = 16
        button.cornerStyle = .fixed
        button.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
        button.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { [weak self] attributes in
            var result = attributes
            result.font = .preferredFont(forTextStyle: .body, compatibleWith: self?.traitCollection)
            return result
        }
        closeButton.configuration = button
        closeButton.titleLabel?.adjustsFontForContentSizeCategory = true
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: ShareStatusView, _: UITraitCollection) in
            view.closeButton.setNeedsUpdateConfiguration()
        }
        closeButton.accessibilityIdentifier = "share.close"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            name.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 18),
            name.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: layoutMarginsGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -8),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            closeButton.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            closeButton.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            closeButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])
        render(status: "Preparing screenshots…", detail: "", stage: 0)
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func render(title: String = "Dropping into\nCodex", status: String, detail: String, stage: Int?, working: Bool = true, buttonTitle: String = "Cancel") {
        headline.text = title
        self.status.text = status
        self.detail.text = detail
        self.detail.isHidden = detail.isEmpty
        stages.isHidden = stage == nil
        for (index, dot) in dots.enumerated() {
            let complete = index < (stage ?? 0)
            dot.image = UIImage(systemName: complete ? "checkmark.circle.fill" : "circle.fill")
            dot.tintColor = complete ? DropBrand.mint : index == stage ? DropBrand.lavender : UIColor(white: 0.4, alpha: 1)
        }
        if let stage {
            stages.accessibilityLabel = ["Find your Mac", "Transfer images", "Attach to draft"].enumerated().map { index, label in
                "\(label): \(index < stage ? "complete" : index == stage ? "in progress" : "waiting")"
            }.joined(separator: ". ")
        }
        if working { spinner.startAnimating() } else { spinner.stopAnimating() }
        closeButton.setTitle(buttonTitle, for: .normal)
        closeButton.accessibilityHint = buttonTitle == "Cancel" ? "Stops this share before attachment begins." : working ? "Dismisses this sheet. Delivery will continue on your Mac." : "Dismisses this sheet."
    }
}
