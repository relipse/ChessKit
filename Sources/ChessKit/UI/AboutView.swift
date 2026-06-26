import SwiftUI

/// About the app + the developer's personal testimony.
public struct AboutView: View {
    let brand: Brand
    @Environment(\.dismiss) private var dismiss

    public init(brand: Brand) { self.brand = brand }

    // The developer's testimony — reproduced verbatim; do not edit.
    private let testimony = """
My name is Jim. I wanted to share how I came to Christ in repentance and faith. My parents got divorced when I was around 2 and my dad got custody. My dad was an airline pilot so he traveled a lot. I had many nannies but only one was very vocal about her faith in Jesus Christ. My pet sin was stealing. I stole computer software, music, expensive calculators, chess sets. I hacked people's computers and got involved in the dark internet at all manner of nights when my dad was sleeping. My dad never taught me the Bible and when I went to college at UMBC (University of Maryland, Baltimore County), I went with the idea of getting away from his rule and getting involved with the ladies. And that's exactly what I did.

One day, I was studying Calculus and this lady walked up to me. She asked me if I wanted to study the Bible I hesitantly said "sure" and she got her husband to start Bible studies with me an hour once per week.

The Bible studies were very challenging to me. We started in the book of Genesis and slowly over several months, I began to be convicted of my wicked lifestyle. I tried to stop sinning, I made bets with my friends but could not stop.

One day I was feeling hopeless after messing up again and I started apologizing to God. "I'm sorry I'm sorry" but nothing happened. I randomly opened the Bible and the page landed on 1 Thessalonians 4

"It is God's will that you would be sanctified, that you would avoid sexual immorality, that you would learn to control your body in a way that is holy and honorable, not in passionate lust like the heathen, who don't know God" (how I saw it)

That cut me to my heart…How did God know me? And He knew my struggles.

At that moment, I fell on my knees and asked God to forgive me. And he did, I heard something say "You're clean" I said "I don't believe You" because I was so filthy. And I heard it a second time "You're clean" and I rose up forgiven of all my sins and the happiest man alive. I had a permanent smile on my face for months because I couldn't fathom how God could forgive me a wicked person.

The very next week we studied the gospel of John chapter 1 and I read

The next day he saw Jesus coming to him and said, "Behold, the Lamb of God who takes away the sin of the world! -John 1:29

And I knew it was Jesus who took away my sins.

The Bible just started making sense to me.

Over a period of time, I got convicted of my theft and I read in the Bible

He who steals must steal no longer; but rather he must labor, performing with his own hands what is good, so that he will have something to share with one who has need. -Ephesians 4:28

I made a phone call and returned money back for a cd drive I had stolen in high school. I repaid back, with interest many places I stole from. By God's grace, I won a chess tournament and won $1200. I knew I had to use that money to buy a piece of software I had stolen (pirated), so I did.

I started Bible studies with many of my previous friends because I wanted them to be saved just like me.

That's how I came to faith in Christ: by trusting in Christ alone for forgiveness.
"""

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: brand.systemImage)
                            .font(.title.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(Theme.heroGradient(brand.accent), in: RoundedRectangle(cornerRadius: 13))
                        VStack(alignment: .leading) {
                            Text(brand.displayTitle).font(.title2.weight(.bold))
                            Text("Kinsman Software LLC").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Text("Play \(brand.displayTitle) against the computer. Part of a family of chess apps by Kinsman Software LLC.")
                        .font(.callout).foregroundStyle(.secondary)

                    Divider()
                    Text("A Personal Testimony").font(.title3.weight(.bold)).foregroundStyle(brand.accent)
                    Text(testimony).font(.callout).textSelection(.enabled)

                    Divider()
                    Text("© Kinsman Software LLC").font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(20)
            }
            .navigationTitle("About")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(brand.accent)
    }
}

/// A brief launch splash showing the studio name, then reveals its content.
public struct SplashGate<Content: View>: View {
    let brand: Brand
    @ViewBuilder var content: () -> Content
    @State private var done = false

    public init(brand: Brand, @ViewBuilder content: @escaping () -> Content) {
        self.brand = brand
        self.content = content
    }

    public var body: some View {
        ZStack {
            content()
            if !done {
                splash.transition(.opacity)
            }
        }
        .onAppear {
            Task {
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                withAnimation(.easeOut(duration: 0.45)) { done = true }
            }
        }
    }

    private var splash: some View {
        ZStack {
            Theme.heroGradient(brand.accent).ignoresSafeArea()
            VStack(spacing: 18) {
                if let logo = brand.logoAsset {
                    Image(logo, bundle: .main)
                        .resizable().scaledToFit()
                        .frame(width: 150, height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 33))
                        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                } else {
                    Image(systemName: brand.systemImage)
                        .font(.system(size: 72, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 132, height: 132)
                        .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 30))
                }
                Text(brand.displayTitle)
                    .font(.system(.largeTitle, design: .rounded).weight(.heavy)).foregroundStyle(.white)
                Spacer().frame(height: 8)
                VStack(spacing: 2) {
                    Text("A").font(.caption).foregroundStyle(.white.opacity(0.8))
                    Text("Kinsman Software LLC")
                        .font(.title3.weight(.semibold)).foregroundStyle(.white)
                    Text("production").font(.caption).foregroundStyle(.white.opacity(0.8))
                }
            }
        }
    }
}
