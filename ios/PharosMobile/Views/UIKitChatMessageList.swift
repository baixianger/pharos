import SwiftUI
import UIKit

/// UIKit owns the scroll physics and cell position; SwiftUI still owns the
/// visual message cell. This boundary keeps keyboard/list re-layout from
/// competing with SwiftUI's ScrollPosition state.
struct UIKitChatMessageList: UIViewControllerRepresentable {
    let room: String
    let messages: [MeshMessage]
    let members: [String: MeshMember]
    let hasMoreHistory: Bool
    let isLoadingOlder: Bool
    let isLoadingHistory: Bool
    let scrollToLatestToken: Int
    let composer: AnyView
    let onReply: (MeshMessage) -> Void
    let onOpenAttachment: (MeshAttachment) -> Void
    let onLoadOlder: () -> Void
    let onDismissKeyboard: () -> Void

    func makeUIViewController(context: Context) -> ChatMessageListController {
        ChatMessageListController()
    }

    func updateUIViewController(_ controller: ChatMessageListController, context: Context) {
        controller.onReply = onReply
        controller.onOpenAttachment = onOpenAttachment
        controller.onLoadOlder = onLoadOlder
        controller.onDismissKeyboard = onDismissKeyboard
        controller.apply(messages: messages, members: members,
                         hasMoreHistory: hasMoreHistory,
                         isLoadingOlder: isLoadingOlder,
                         isLoadingHistory: isLoadingHistory,
                         room: room)
        controller.setComposer(composer)
        controller.scrollToLatestIfNeeded(token: scrollToLatestToken)
    }
}

@MainActor
final class ChatMessageListController: UIViewController {
    var onReply: ((MeshMessage) -> Void)?
    var onOpenAttachment: ((MeshAttachment) -> Void)?
    var onLoadOlder: (() -> Void)?
    var onDismissKeyboard: (() -> Void)?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var cells: [ChatListCell] = []
    private var messageByID: [String: MeshMessage] = [:]
    private var memberByNick: [String: MeshMember] = [:]
    private var room = ""
    private var hasMoreHistory = false
    private var isLoadingOlder = false
    private var isLoadingHistory = false
    private var hasAppliedInitialLayout = false
    private var isApplyingSnapshot = false
    private var lastScrollToLatestToken = 0
    private var composerHost: UIHostingController<AnyView>?
    private var composerContainer = UIView()
    private var forceTailAfterNextSnapshot = false
    private var lastObstruction: CGFloat?
    /// Captured before a keyboard/composer constraint pass. If the user was
    /// reading the newest message, the list must follow the moving bottom
    /// edge; if they scrolled up, their reading position must not be stolen.
    private var shouldFollowTailDuringLayout = false
    private var initialTailSettleGeneration = 0
    private var userHasScrolled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        composerContainer.backgroundColor = .clear
        composerContainer.translatesAutoresizingMaskIntoConstraints = false

        let layout = UICollectionViewCompositionalLayout { _, environment in
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                              heightDimension: .estimated(44))
            let item = NSCollectionLayoutItem(layoutSize: size)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
            return section
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "ChatCell")
        collectionView.backgroundColor = .systemBackground
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.delegate = self
        // The list owns its bottom obstruction (composer + keyboard). Letting
        // UIKit also apply automatic safe-area insets here double-counts the
        // obstruction and is the source of the transient blank band.
        collectionView.contentInsetAdjustmentBehavior = .never
        view.addSubview(collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composerContainer)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            composerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerContainer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        ])

        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) {
            [weak self] collectionView, indexPath, identifier in
            guard let self, let cell = self.cells.first(where: { $0.id == identifier }) else { return nil }
            let reusableCell = collectionView.dequeueReusableCell(withReuseIdentifier: "ChatCell", for: indexPath)
            reusableCell.contentConfiguration = UIHostingConfiguration { self.view(for: cell) }
                .margins(.all, 0)
            return reusableCell
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scheduleInitialTailSettle()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        guard collectionView != nil, !isApplyingSnapshot else { return }
        shouldFollowTailDuringLayout = isAtTail
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard collectionView != nil, !isApplyingSnapshot else { return }
        let obstruction = max(0, view.bounds.maxY - composerContainer.frame.minY)
        let wasAtTail = isAtTail
        let obstructionDelta = lastObstruction.map { obstruction - $0 } ?? 0
        lastObstruction = obstruction
        if abs(collectionView.contentInset.bottom - obstruction) > 0.5 {
            collectionView.contentInset.bottom = obstruction
            collectionView.scrollIndicatorInsets.bottom = obstruction
        }
        let shouldSetInitialTail = !userHasScrolled && !cells.isEmpty && !hasAppliedInitialLayout
        if wasAtTail || shouldFollowTailDuringLayout || shouldSetInitialTail {
            // UIKeyboardLayoutGuide is animating the composer and the list
            // obstruction together. Recompute the exact tail offset on each
            // layout pass so the whole transcript moves with the keyboard.
            setTailOffset()
        } else if abs(obstructionDelta) > 0.5 {
            // Keep a user reading older history moving with the keyboard too.
            // The visible anchor is translated by the exact obstruction
            // delta instead of being forced to the newest message.
            setContentOffsetClamped(y: collectionView.contentOffset.y + obstructionDelta)
        }
        shouldFollowTailDuringLayout = false
    }

    func setComposer(_ composer: AnyView) {
        if let composerHost {
            composerHost.rootView = composer
            composerHost.view.invalidateIntrinsicContentSize()
            return
        }
        let host = UIHostingController(rootView: composer)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        composerContainer.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: composerContainer.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: composerContainer.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: composerContainer.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: composerContainer.bottomAnchor)
        ])
        host.didMove(toParent: self)
        composerHost = host
    }

    func apply(messages: [MeshMessage], members: [String: MeshMember],
               hasMoreHistory: Bool, isLoadingOlder: Bool, isLoadingHistory: Bool, room: String) {
        guard self.room != room || self.cells.map(\.id) != makeCells(messages: messages, hasMoreHistory: hasMoreHistory, isLoadingHistory: isLoadingHistory).map(\.id)
                || self.isLoadingOlder != isLoadingOlder || self.isLoadingHistory != isLoadingHistory else {
            return
        }

        let isNewRoom = self.room != room
        // The first render can be an empty/loading state while the broker
        // response is in flight. When the first real page arrives, that is
        // still an opening transition and must land at the tail; restoring
        // the empty-state anchor is what previously left rooms mid-history.
        let isFirstMessagePage = !containsMessageCell && !messages.isEmpty
        let shouldStartAtTail = isNewRoom || isFirstMessagePage
        let wasAtTail = isAtTail
        let anchor = visibleAnchor()
        self.room = room
        self.memberByNick = members
        self.messageByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        self.hasMoreHistory = hasMoreHistory
        self.isLoadingOlder = isLoadingOlder
        self.isLoadingHistory = isLoadingHistory
        self.cells = makeCells(messages: messages, hasMoreHistory: hasMoreHistory, isLoadingHistory: isLoadingHistory)

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(cells.map(\.id))
        isApplyingSnapshot = true
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.isApplyingSnapshot = false
            if shouldStartAtTail {
                self.hasAppliedInitialLayout = true
                self.setTailOffset()
                self.scheduleInitialTailSettle()
            } else if self.forceTailAfterNextSnapshot {
                self.forceTailAfterNextSnapshot = false
                self.scrollToTail(animated: false)
            } else if !self.hasAppliedInitialLayout {
                self.hasAppliedInitialLayout = true
                self.scheduleInitialTailSettle()
            } else if wasAtTail {
                self.scrollToTail(animated: false)
            } else if let anchor {
                self.restore(anchor: anchor)
            }
        }
    }

    private var containsMessageCell: Bool {
        cells.contains {
            if case .message = $0 { return true }
            return false
        }
    }

    func scrollToLatestIfNeeded(token: Int) {
        guard token != lastScrollToLatestToken else { return }
        lastScrollToLatestToken = token
        guard token > 0 else { return }
        // The broker refresh may apply a new snapshot after this callback. Do
        // not let that snapshot restore the user's old history anchor.
        forceTailAfterNextSnapshot = true
        DispatchQueue.main.async { [weak self] in self?.scrollToTail(animated: true) }
    }

    private var isAtTail: Bool {
        let maximumOffset = max(
            -collectionView.adjustedContentInset.top,
            collectionView.contentSize.height - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        return collectionView.contentOffset.y >= maximumOffset - 48
    }

    private func visibleAnchor() -> VisibleAnchor? {
        guard let indexPath = collectionView.indexPathsForVisibleItems.sorted().first,
              indexPath.item < cells.count else { return nil }
        let id = cells[indexPath.item].id
        let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
        return VisibleAnchor(id: id, offset: frame.map { collectionView.contentOffset.y - $0.minY } ?? 0)
    }

    private func restore(anchor: VisibleAnchor) {
        guard let index = cells.firstIndex(where: { $0.id == anchor.id }) else { return }
        let indexPath = IndexPath(item: index, section: 0)
        collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
        collectionView.contentOffset.y -= anchor.offset
    }

    private func scrollToTail(animated: Bool) {
        guard !cells.isEmpty else { return }
        collectionView.layoutIfNeeded()
        let minimumOffset = -collectionView.adjustedContentInset.top
        let maximumOffset = max(
            minimumOffset,
            collectionView.contentSize.height - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        let offset = CGPoint(x: collectionView.contentOffset.x, y: maximumOffset)
        collectionView.setContentOffset(offset, animated: animated)
    }

    private func setTailOffset() {
        guard !cells.isEmpty else { return }
        let minimumOffset = -collectionView.adjustedContentInset.top
        let maximumOffset = max(
            minimumOffset,
            collectionView.contentSize.height - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: maximumOffset),
            animated: false
        )
    }

    private func setContentOffsetClamped(y: CGFloat) {
        let minimumOffset = -collectionView.adjustedContentInset.top
        let maximumOffset = max(
            minimumOffset,
            collectionView.contentSize.height - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x,
                    y: min(max(y, minimumOffset), maximumOffset)),
            animated: false
        )
    }

    private func scheduleInitialTailSettle() {
        guard !cells.isEmpty, !userHasScrolled else { return }
        initialTailSettleGeneration += 1
        let generation = initialTailSettleGeneration
        // The composer contains the @agent strip and may resolve its SwiftUI
        // intrinsic height after the collection snapshot. Re-apply the exact
        // tail after each relevant layout window, while still allowing a real
        // drag to cancel the sequence immediately.
        for delay in [0.0, 0.05, 0.15, 0.3, 0.6, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, generation == self.initialTailSettleGeneration,
                      !self.userHasScrolled, !self.cells.isEmpty else { return }
                self.view.layoutIfNeeded()
                self.setTailOffset()
            }
        }
    }

    private func makeCells(messages: [MeshMessage], hasMoreHistory: Bool, isLoadingHistory: Bool) -> [ChatListCell] {
        var cells: [ChatListCell] = []
        if messages.isEmpty && isLoadingHistory {
            cells.append(.loading)
            return cells
        }
        if hasMoreHistory { cells.append(.loader) }
        for (index, message) in messages.enumerated() {
            if index == 0 || !Calendar.current.isDate(message.date, inSameDayAs: messages[index - 1].date) {
                cells.append(.divider(id: "day-\(message.id)", date: message.date))
            }
            let grouped = index > 0 && messages[index - 1].from == message.from
                && message.date.timeIntervalSince(messages[index - 1].date) <= 5 * 60
            cells.append(.message(message, showsHeader: !grouped))
        }
        if !hasMoreHistory && messages.isEmpty { cells.append(.welcome(room: room)) }
        return cells
    }

    @ViewBuilder
    private func view(for cell: ChatListCell) -> some View {
        switch cell {
        case .loading:
            ProgressView("Loading messages…").frame(maxWidth: .infinity).padding(.vertical, 24)
        case .loader:
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 14)
        case .divider(_, let date):
            HStack(spacing: 10) { Divider(); Text(date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).fixedSize(); Divider() }
                .padding(.horizontal, 16).padding(.vertical, 12)
        case .message(let message, let showsHeader):
            MessageRow(message: message, member: memberByNick[message.from], showsHeader: showsHeader,
                       onReply: { [weak self] in self?.onReply?(message) },
                       onOpenAttachment: { [weak self] attachment in self?.onOpenAttachment?(attachment) })
                .accessibilityIdentifier("chat-message-\(message.id)")
                .contextMenu {
                    Button("Reply", systemImage: "arrowshape.turn.up.left") { self.onReply?(message) }
                    Button("Copy message", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
                }
        case .welcome(let room):
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "number").font(.title.weight(.bold)).foregroundStyle(.tint)
                    .frame(width: 52, height: 52).background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 16))
                Text("# \(room)").font(.title2.weight(.bold))
                Text("This is the beginning of the room.").font(.subheadline).foregroundStyle(.secondary)
            }.padding(16)
        }
    }

    private struct VisibleAnchor { let id: String; let offset: CGFloat }
}

extension ChatMessageListController: UICollectionViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userHasScrolled = true
        initialTailSettleGeneration += 1
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onDismissKeyboard?()
        // The composer is a UIKit sibling managed by keyboardLayoutGuide. A
        // SwiftUI FocusState change alone may not resign the hosted field, so
        // explicitly end editing at the container boundary.
        view.window?.endEditing(true)
        collectionView.deselectItem(at: indexPath, animated: false)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard indexPath.item == 0, hasMoreHistory, !isLoadingOlder, !isApplyingSnapshot else { return }
        onLoadOlder?()
    }
}

private enum ChatListCell {
    case loading
    case loader
    case divider(id: String, date: Date)
    case message(MeshMessage, showsHeader: Bool)
    case welcome(room: String)

    var id: String {
        switch self {
        case .loading: return "history-loading"
        case .loader: return "history-loader"
        case .divider(let id, _): return id
        case .message(let message, _): return message.id
        case .welcome(let room): return "welcome-\(room)"
        }
    }
}
