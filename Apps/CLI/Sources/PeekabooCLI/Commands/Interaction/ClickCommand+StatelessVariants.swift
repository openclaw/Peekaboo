import PeekabooFoundation

extension ClickCommand {
    var requestedClickType: ClickType {
        if self.longPress {
            .longPress
        } else if self.middle {
            .middle
        } else if self.triple {
            .triple
        } else if self.right {
            .right
        } else if self.double {
            .double
        } else {
            .single
        }
    }
}
