import UIKit
import GreetingKit

final class ActionViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = greeting()
    }
}
