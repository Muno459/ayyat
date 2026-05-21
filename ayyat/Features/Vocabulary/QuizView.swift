import SwiftUI

/// Flashcard quiz: Arabic script on front, meaning on back.
/// Swipe right = Got It, swipe left = Still Learning.
/// Tap to flip the card.
struct QuizView: View {
    @Environment(VocabularyStore.self) private var vocabularyStore
    @State private var quizWords: [WordLearningState] = []
    @State private var currentIndex = 0
    @State private var isFlipped = false
    @State private var score = 0
    @State private var totalAnswered = 0
    @State private var sessionComplete = false
    @State private var dragOffset: CGSize = .zero
    @State private var cardRotation: Double = 0
    /// Edge the *outgoing* card flies toward during the removal
    /// transition. Set on swipe so each card exits the same way the
    /// user flung it.
    @State private var lastSwipeDirection: Edge = .trailing
    /// Identity of the card the live drag belongs to. The new card
    /// (currentIndex + 1) should never inherit the previous card's
    /// drag-offset / rotation, otherwise it briefly appears mid-air on
    /// mount before settling. The outgoing card's motion is handled by
    /// the SwiftUI removal transition.
    @State private var liveCardIndex: Int = 0

    // Gamification states
    @State private var streak = 0
    @State private var bestStreak = 0
    @State private var xpEarned = 0
    @State private var showXPPopup = false
    @State private var lastXPGain = 0
    @State private var showStreakFlame = false
    @State private var cardScale: CGFloat = 1.0
    @State private var showConfetti = false
    @State private var encouragement = ""
    @State private var showEncouragement = false
    /// Flipped to false in `.onDisappear` so the async tasks below don't
    /// mutate state after the view has been popped from the stack.
    @State private var isActive = true

    private let encouragements = ["Amazing!", "Perfect!", "You got this!", "Excellent!", "Keep going!", "Brilliant!", "Mashallah!"]
    private let streakEncouragements = ["On fire!", "Unstoppable!", "Incredible streak!", "You're a star!"]

    private var currentWord: WordLearningState? {
        guard currentIndex < quizWords.count else { return nil }
        return quizWords[currentIndex]
    }

    private var comboMultiplier: Int {
        if streak >= 7 { return 3 }
        if streak >= 4 { return 2 }
        return 1
    }

    var body: some View {
        Group {
            if quizWords.isEmpty {
                emptyState
            } else if sessionComplete {
                completionView
            } else if let word = currentWord {
                quizContent(word: word)
            }
        }
        .navigationTitle("Vocabulary Quiz")
        .onDisappear { isActive = false }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadQuizWords() }
    }

    // MARK: - Quiz Content

    private func quizContent(word: WordLearningState) -> some View {
        ZStack {
            VStack(spacing: 0) {
                // Top stats bar
                HStack(spacing: 16) {
                    // Progress
                    Text("\(currentIndex + 1)/\(quizWords.count)")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(AyyatColors.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(AyyatColors.unseen.opacity(0.1)))

                    Spacer()

                    // Streak indicator
                    if streak > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "flame.fill")
                                .foregroundStyle(.orange)
                                .symbolEffect(.bounce, value: streak)
                            Text("\(streak)")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(.orange)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.orange.opacity(0.15)))
                        .transition(.scale.combined(with: .opacity))
                    }

                    // XP counter
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(AyyatColors.gold)
                        Text("\(xpEarned)")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(AyyatColors.gold)
                            .contentTransition(.numericText())
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(AyyatColors.gold.opacity(0.15)))
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .animation(.spring(response: 0.3), value: streak)

                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(AyyatColors.unseen.opacity(0.15))
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                LinearGradient(
                                    colors: [AyyatColors.primary, AyyatColors.gold],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * CGFloat(currentIndex) / CGFloat(max(quizWords.count, 1)), height: 6)
                            .animation(.spring(response: 0.4), value: currentIndex)
                    }
                }
                .frame(height: 6)
                .padding(.horizontal, 20)
                .padding(.top, 12)

                // Combo multiplier badge
                if comboMultiplier > 1 {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11))
                        Text("\(comboMultiplier)x COMBO")
                            .font(.system(size: 11, weight: .heavy))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(LinearGradient(colors: [.purple, .pink], startPoint: .leading, endPoint: .trailing)))
                    .transition(.scale.combined(with: .opacity))
                    .padding(.top, 8)
                }

                Spacer()

            // Card with drag gesture.
            //
            // The card lives in its OWN view (`SwipeableQuizCard`) with
            // private `@State` for offset/rotation. That way the next
            // card's mount starts with a fresh offset of .zero — it
            // can't inherit the previous card's drag value, which was
            // the source of the "card stays stuck mid-swipe and the new
            // one never appears" bug. The parent only learns the swipe
            // outcome (left vs right) via the `onCommit` callback after
            // the fly-off animation has played.
            SwipeableQuizCard(
                isFlipped: $isFlipped,
                cardScale: cardScale,
                content: { cardView(word: word) },
                onCommit: { correct in
                    swipeAway(correct: correct, word: word)
                }
            )
            .id(currentIndex)
            .transition(
                .asymmetric(
                    insertion: .move(edge: .bottom)
                        .combined(with: .opacity)
                        .combined(with: .scale(scale: 0.85)),
                    removal: .opacity   // SwipeableQuizCard handles its own off-screen translation
                )
            )

            Spacer()

                // Bottom hint
                if !isFlipped {
                    Text("Tap card to reveal meaning")
                        .font(.system(size: 13))
                        .foregroundStyle(AyyatColors.textSecondary)
                        .padding(.bottom, 8)
                } else {
                    Text("Swipe right if you know it, left if not")
                        .font(.system(size: 13))
                        .foregroundStyle(AyyatColors.textSecondary)
                        .padding(.bottom, 8)
                }

                // Button fallback (for accessibility)
                if isFlipped {
                    HStack(spacing: 16) {
                        Button { swipeAway(correct: false, word: word) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "xmark")
                                Text("Learning")
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: 14).fill(AyyatColors.learning))
                        }
                        Button { swipeAway(correct: true, word: word) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark")
                                Text("Got It")
                                if comboMultiplier > 1 {
                                    Text("+\(10 * comboMultiplier)")
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(.white.opacity(0.3)))
                                }
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: 14).fill(AyyatColors.mastered))
                        }
                    }
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                Spacer().frame(height: 24)
            }
            .background(AyyatColors.background)

            // XP Popup overlay
            if showXPPopup {
                VStack(spacing: 4) {
                    Text("+\(lastXPGain) XP")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .foregroundStyle(AyyatColors.gold)
                    if comboMultiplier > 1 {
                        Text("\(comboMultiplier)x Combo!")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.purple)
                    }
                }
                .transition(.scale.combined(with: .opacity).combined(with: .move(edge: .bottom)))
                .offset(y: -50)
            }

            // Encouragement overlay
            if showEncouragement {
                Text(encouragement)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(AyyatColors.mastered)
                    .transition(.scale.combined(with: .opacity))
                    .offset(y: -120)
            }

            // Confetti overlay
            if showConfetti {
                ConfettiView()
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Card View (front/back flip)

    private func cardView(word: WordLearningState) -> some View {
        ZStack {
            // Front: Arabic
            VStack(spacing: 16) {
                Text(word.masteryLevel.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(masteryColor(word.masteryLevel))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(masteryColor(word.masteryLevel).opacity(0.1)))

                Spacer()

                Text(displayText(for: word))
                    .font(.system(size: vocabularyStore.useTransliteration ? 36 : 48))
                    .foregroundStyle(AyyatColors.textPrimary)
                    .multilineTextAlignment(.center)

                Text("?")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(AyyatColors.textSecondary.opacity(0.3))

                Spacer()
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: 340)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(AyyatColors.cardBackground)
                    .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
            )
            .opacity(isFlipped ? 0 : 1)
            .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))

            // Back: Meaning
            VStack(spacing: 16) {
                Text(displayText(for: word))
                    .font(.system(size: vocabularyStore.useTransliteration ? 22 : 28))
                    .foregroundStyle(AyyatColors.primary)

                Spacer()

                Text(word.translationText)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(AyyatColors.textPrimary)
                    .multilineTextAlignment(.center)

                Spacer()
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: 340)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(AyyatColors.cardBackground)
                    .shadow(color: AyyatColors.primary.opacity(0.12), radius: 16, y: 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .strokeBorder(AyyatColors.primary.opacity(0.15), lineWidth: 1)
                    )
            )
            .opacity(isFlipped ? 1 : 0)
            .rotation3DEffect(.degrees(isFlipped ? 0 : -180), axis: (x: 0, y: 1, z: 0))
        }
        .padding(.horizontal, 24)
        .onTapGesture {
            Haptics.light()
            withAnimation(.easeInOut(duration: 0.4)) {
                isFlipped.toggle()
            }
        }
    }

    // MARK: - Swipe Away

    private func swipeAway(correct: Bool, word: WordLearningState) {
        totalAnswered += 1

        if correct {
            // Success feedback
            Haptics.success()
            score += 1
            streak += 1
            bestStreak = max(bestStreak, streak)
            vocabularyStore.promote(wordId: word.wordId)

            // Calculate XP with combo
            let baseXP = 10
            let xpGain = baseXP * comboMultiplier
            lastXPGain = xpGain
            xpEarned += xpGain

            // Show XP popup
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                showXPPopup = true
            }

            // Show encouragement for streaks
            if streak >= 3 {
                encouragement = streakEncouragements.randomElement() ?? "Amazing!"
                withAnimation(.spring(response: 0.3)) {
                    showEncouragement = true
                }
                // Confetti for big streaks
                if streak >= 5 {
                    showConfetti = true
                }
            } else {
                encouragement = encouragements.randomElement() ?? "Great!"
                withAnimation(.spring(response: 0.3)) {
                    showEncouragement = true
                }
            }

            // Hide popups before the next card transitions in, so the
            // encouragement / XP / confetti don't visually stack on top
            // of the incoming card. Sequencing:
            //   0.0s – correct answer fires, popups appear
            //   0.5s – popups start fading
            //   0.85s – next card slides in
            scheduleAfter(0.5) {
                withAnimation(.easeOut(duration: 0.3)) {
                    showXPPopup = false
                    showEncouragement = false
                    showConfetti = false
                }
            }

        } else {
            // Wrong answer feedback
            Haptics.error()
            streak = 0
            vocabularyStore.demote(wordId: word.wordId)

            // Shake animation
            withAnimation(.spring(response: 0.1, dampingFraction: 0.3)) {
                cardScale = 0.95
            }
            scheduleAfter(0.1) {
                withAnimation(.spring(response: 0.2)) {
                    cardScale = 1.0
                }
            }
        }

        // The outgoing card already animated itself off-screen inside
        // `SwipeableQuizCard`. We just advance the deck — the new card's
        // identity change drives its own insertion transition.
        lastSwipeDirection = correct ? .trailing : .leading

        // Tiny delay so the score popup / streak haptic land while the
        // old card is still fading, not blocked by an immediate cut.
        scheduleAfter(0.15) {
            isFlipped = false
            if currentIndex + 1 < quizWords.count {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                    currentIndex += 1
                }
            } else {
                sessionComplete = true
                Haptics.success()
            }
        }
    }

    /// Schedules `body` after `seconds` on the main actor, guarded by
    /// `isActive` so the closure no-ops if the view has been dismissed.
    /// Replaces `DispatchQueue.main.asyncAfter`, which kept mutating
    /// `@State` after the user popped the view — visible as purple runtime
    /// warnings and stale state flashes on the next view shown.
    private func scheduleAfter(_ seconds: Double, _ body: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard isActive else { return }
            body()
        }
    }

    // MARK: - Empty / Completion

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 56))
                .foregroundStyle(AyyatColors.primary.opacity(0.3))
            Text("No words to review yet")
                .font(.system(size: 18, weight: .medium))
            Text("Start reading the Quran to build your vocabulary.")
                .font(.system(size: 14))
                .foregroundStyle(AyyatColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AyyatColors.background)
    }

    private var completionView: some View {
        let pct = totalAnswered > 0 ? Int(Double(score) / Double(totalAnswered) * 100) : 0
        let grade = pct >= 90 ? "S" : pct >= 80 ? "A" : pct >= 70 ? "B" : pct >= 60 ? "C" : "D"
        let isPerfect = score == totalAnswered && totalAnswered > 0

        return ZStack {
            VStack(spacing: 16) {
                Spacer()

                // Grade badge
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: isPerfect ? [.yellow, .orange] : [AyyatColors.primary, AyyatColors.primary.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 100, height: 100)
                        .shadow(color: isPerfect ? .orange.opacity(0.5) : AyyatColors.primary.opacity(0.3), radius: 20)

                    Text(grade)
                        .font(.system(size: 48, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                }
                .scaleEffect(isPerfect ? 1.1 : 1.0)
                .animation(.spring(response: 0.5, dampingFraction: 0.6).repeatForever(autoreverses: true), value: isPerfect)

                Text(isPerfect ? "Perfect!" : "Session Complete")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(AyyatColors.textPrimary)

                // Stats grid
                HStack(spacing: 24) {
                    VStack(spacing: 4) {
                        Text("\(score)/\(totalAnswered)")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(AyyatColors.mastered)
                        Text("Correct")
                            .font(.system(size: 12))
                            .foregroundStyle(AyyatColors.textSecondary)
                    }

                    VStack(spacing: 4) {
                        HStack(spacing: 2) {
                            Image(systemName: "flame.fill")
                                .foregroundStyle(.orange)
                            Text("\(bestStreak)")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(.orange)
                        }
                        Text("Best Streak")
                            .font(.system(size: 12))
                            .foregroundStyle(AyyatColors.textSecondary)
                    }

                    VStack(spacing: 4) {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .foregroundStyle(AyyatColors.gold)
                            Text("\(xpEarned)")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(AyyatColors.gold)
                        }
                        Text("XP Earned")
                            .font(.system(size: 12))
                            .foregroundStyle(AyyatColors.textSecondary)
                    }
                }
                .padding(.top, 8)

                // Motivational message
                Text(pct >= 80 ? "Excellent work! Keep it up!" : pct >= 50 ? "Good effort! Practice makes perfect." : "Keep learning, you'll get there!")
                    .font(.system(size: 14))
                    .foregroundStyle(AyyatColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, 8)

                Spacer()

                Button {
                    resetQuiz()
                } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Practice Again")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(RoundedRectangle(cornerRadius: 14).fill(AyyatColors.primary))
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AyyatColors.background)

            if isPerfect {
                ConfettiView()
                    .allowsHitTesting(false)
            }
        }
    }

    private func resetQuiz() {
        loadQuizWords()
        sessionComplete = false
        currentIndex = 0
        score = 0
        totalAnswered = 0
        streak = 0
        bestStreak = 0
        xpEarned = 0
    }

    // MARK: - Logic

    private func displayText(for word: WordLearningState) -> String {
        if vocabularyStore.useTransliteration {
            return word.transliterationText.isEmpty ? word.arabicText : word.transliterationText
        }
        return word.arabicText
    }

    private func loadQuizWords() {
        quizWords = Array(
            vocabularyStore.wordStates.values
                .filter { $0.masteryLevel >= .introduced && !$0.arabicText.isEmpty }
                .sorted { a, b in
                    if a.masteryLevel != b.masteryLevel { return a.masteryLevel < b.masteryLevel }
                    return (a.lastSeenDate ?? .distantPast) < (b.lastSeenDate ?? .distantPast)
                }
                .prefix(10)
        )
    }

    private func masteryColor(_ level: MasteryLevel) -> Color {
        switch level {
        case .unseen: AyyatColors.unseen
        case .introduced: AyyatColors.introduced
        case .learning: AyyatColors.learning
        case .familiar: AyyatColors.introduced
        case .mastered: AyyatColors.mastered
        }
    }
}

// MARK: - Swipeable quiz card
//
// Owns its own offset / rotation state so a freshly-mounted card
// (after the parent's `currentIndex` advances) starts at .zero —
// it cannot inherit the previous card's drag value. This was the
// fix for the "card stays mid-swipe, next card never appears" bug.
struct SwipeableQuizCard<Content: View>: View {
    @Binding var isFlipped: Bool
    let cardScale: CGFloat
    @ViewBuilder let content: () -> Content
    /// Called once after the card has animated off-screen. `true` =
    /// right swipe (got it), `false` = left swipe (still learning).
    let onCommit: (Bool) -> Void

    @State private var offset: CGSize = .zero
    @State private var committed = false   // guards against double-trigger

    var body: some View {
        content()
            .scaleEffect(cardScale)
            .offset(offset)
            .rotationEffect(.degrees(offset.width / 20))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard !committed else { return }
                        offset = value.translation
                    }
                    .onEnded { value in
                        guard !committed else { return }
                        if value.translation.width > 100 {
                            commit(correct: true)
                        } else if value.translation.width < -100 {
                            commit(correct: false)
                        } else {
                            // Snap back to center on a non-committal flick.
                            withAnimation(.spring(response: 0.3)) {
                                offset = .zero
                            }
                        }
                    }
            )
    }

    private func commit(correct: Bool) {
        committed = true
        // Fly the card fully off-screen in the swipe direction. 900 pt
        // is wider than any current iPhone, so the card is genuinely
        // gone before the parent swaps in the next one.
        withAnimation(.easeOut(duration: 0.28)) {
            offset = CGSize(width: correct ? 900 : -900, height: 0)
        }
        // Signal the parent slightly *after* the fly-off so the
        // outgoing card is visually off-screen before the next card's
        // mount animation begins — no overlap, no flash.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.30))
            onCommit(correct)
        }
    }
}

// MARK: - Confetti View

struct ConfettiView: View {
    @State private var particles: [ConfettiParticle] = []

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(particles) { particle in
                    confettiShape(particle)
                        .fill(particle.color)
                        .frame(width: particle.size,
                               height: particle.shape == 1 ? particle.size * 1.8 : particle.size)
                        .rotationEffect(.degrees(particle.rotation))
                        .position(particle.position)
                        .opacity(particle.opacity)
                }
            }
            .onAppear {
                createParticles(in: geo.size)
                animateParticles(in: geo.size)
            }
        }
        .allowsHitTesting(false)
    }

    private func confettiShape(_ p: ConfettiParticle) -> AnyShape {
        // Mix of circles (40%), rectangles/streamers (40%), capsules (20%) —
        // gives the falling confetti visual variety. Each shape uses the
        // ConfettiParticle.shape index assigned at spawn.
        switch p.shape {
        case 0: return AnyShape(Circle())
        case 1: return AnyShape(RoundedRectangle(cornerRadius: 1.5))
        default: return AnyShape(Capsule())
        }
    }

    private func createParticles(in size: CGSize) {
        guard size.width > 0 && size.height > 0 else { return }

        // Festive but tasteful palette — gold + the ayyat primary accent
        // weighted heavier so it doesn't look like a generic party popper.
        let colors: [Color] = [
            AyyatColors.gold, AyyatColors.gold, AyyatColors.primary,
            .orange, .yellow, .pink, .purple, .mint,
        ]
        // 80 pieces with a wider spawn x range so the screen really looks
        // showered, not a 50-particle line.
        particles = (0..<80).map { _ in
            ConfettiParticle(
                position: CGPoint(
                    x: CGFloat.random(in: -20...(size.width + 20)),
                    // Stagger spawn y so they don't all enter at the same
                    // line — feels more organic falling-in.
                    y: CGFloat.random(in: -60 ... -10)
                ),
                color: colors.randomElement() ?? .yellow,
                size: CGFloat.random(in: 5...11),
                opacity: 1,
                rotation: Double.random(in: 0...360)
            )
        }
    }

    private func animateParticles(in size: CGSize) {
        guard size.width > 0 && size.height > 0 && !particles.isEmpty else { return }

        // Two-phase animation — fall + flutter + fade out. Each piece
        // has its own delay (up to 0.8 s) and duration (3–4.5 s) so
        // they don't all land at the same beat. Easings vary between
        // particles for a less mechanical feel.
        let easings: [Animation] = [
            .easeOut(duration: 3.5),
            .easeInOut(duration: 4.0),
            .timingCurve(0.2, 0.8, 0.3, 1.0, duration: 3.8),
        ]
        for i in particles.indices {
            let delay = Double.random(in: 0...0.8)
            let duration = Double.random(in: 3.0...4.5)
            let curve = easings.randomElement() ?? .easeOut(duration: duration)

            withAnimation(curve.delay(delay)) {
                particles[i].position.y = size.height + 80
                // Wider horizontal drift so they look like they're caught
                // in a breeze rather than falling straight down.
                particles[i].position.x += CGFloat.random(in: -180...180)
                particles[i].rotation += Double.random(in: 360...900)
            }
            // Fade out only near the end of the fall so the pieces
            // actually finish their flight before disappearing.
            withAnimation(.easeIn(duration: 0.6).delay(delay + duration - 0.6)) {
                particles[i].opacity = 0
            }
        }
    }
}

struct ConfettiParticle: Identifiable {
    let id = UUID()
    var position: CGPoint
    let color: Color
    let size: CGFloat
    var opacity: Double
    /// Degrees of rotation — animated through the fall so confetti
    /// looks like it's tumbling instead of sliding.
    var rotation: Double = 0
    /// Shape rolled at spawn: 0 = disc, 1 = rectangle (strip), 2 = star.
    let shape: Int = Int.random(in: 0...2)
}
