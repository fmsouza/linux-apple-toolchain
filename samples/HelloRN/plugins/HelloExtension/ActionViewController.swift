import UIKit

// A minimal Action extension: shows a label and a Done button that returns to the host app.
class ActionViewController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground

    let label = UILabel()
    label.text = "Hello from HelloExtension"
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)

    let done = UIButton(type: .system)
    done.setTitle("Done", for: .normal)
    done.addTarget(self, action: #selector(finish), for: .touchUpInside)
    done.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(done)

    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      done.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      done.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
    ])
  }

  @objc private func finish() {
    extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
  }
}
