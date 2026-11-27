import SwiftUI

// MARK: - Browser tree (sidebar)

struct BrowserRow: Identifiable {
    enum Disclosure { case none, open, closed }
    enum Eye { case none, on, off }
    let id = UUID()
    var indent: Int
    var disclosure: Disclosure = .none
    var symbol: String? = nil
    var symbolTint: Color? = nil
    var status: StageStatus? = nil
    var title: String
    var detail: String? = nil
    var eye: Eye = .on
    var selected = false
    var section = false
}

struct OutputRow: Identifiable {
    let id = UUID()
    var symbol: String
    var title: String
    var status: StageStatus
    var value: String? = nil
}

struct BrowserPanel: View {
    var title = "Browser"
    let rows: [BrowserRow]
    let outputs: [OutputRow]

    var body: some View {
        VStack(spacing: 0) {
            header(title, symbol: "line.3.horizontal")
            VStack(spacing: 0) {
                ForEach(rows) { BrowserRowView(row: $0) }
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
            Hairline()
            header("Pipeline outputs", symbol: "rectangle.compress.vertical")
            VStack(spacing: 0) {
                ForEach(outputs) { OutputRowView(row: $0) }
            }
            .padding(.bottom, 8)
        }
        .panelWell()
    }

    private func header(_ text: String, symbol: String) -> some View {
        HStack {
            CapsLabel(text: text, color: VF.text.opacity(0.78))
            Spacer()
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(VF.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
    }
}

struct BrowserRowView: View {
    let row: BrowserRow
    var body: some View {
        HStack(spacing: 6) {
            Group {
                switch row.disclosure {
                case .none: Color.clear
                case .open: Image(systemName: "chevron.down")
                case .closed: Image(systemName: "chevron.right")
                }
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(row.selected ? .white : VF.secondary)
            .frame(width: 12)
            if let status = row.status {
                StatusDot(status: status, size: 9).frame(width: 18)
            } else if let s = row.symbol {
                Image(systemName: s)
                    .font(.system(size: 12.5))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(row.selected ? .white : (row.symbolTint ?? VF.text.opacity(0.82)))
                    .frame(width: 18)
            }
            if row.section {
                CapsLabel(text: row.title, size: 11.5, color: VF.text.opacity(0.85))
            } else {
                Text(row.title).font(.vfRow).lineLimit(1)
            }
            if let d = row.detail {
                Text(d).font(.vfRow).monospacedDigit().foregroundStyle(row.selected ? .white.opacity(0.8) : VF.secondary)
            }
            Spacer(minLength: 4)
            switch row.eye {
            case .none: EmptyView()
            case .on: Image(systemName: "eye.fill").font(.system(size: 10.5)).foregroundStyle(row.selected ? .white : VF.secondary)
            case .off: Image(systemName: "eye.slash").font(.system(size: 10.5)).foregroundStyle(VF.tertiary)
            }
        }
        .padding(.leading, 8 + CGFloat(row.indent) * 16)
        .padding(.trailing, 12)
        .frame(height: 27)
        .foregroundStyle(row.selected ? .white : VF.text.opacity(0.92))
        .background(row.selected ? VF.accent : .clear)
    }
}

struct OutputRowView: View {
    let row: OutputRow
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: row.symbol)
                .font(.system(size: 12))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(row.status == .stale ? VF.amber : VF.text.opacity(0.8))
                .frame(width: 18)
            Text(row.title).font(.system(size: 12.5)).lineLimit(1)
            Spacer(minLength: 4)
            StatusDot(status: row.status, size: 8)
            Text(row.value ?? row.status.word)
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(row.value != nil || row.status == .upToDate ? VF.secondary : row.status.color)
                .frame(width: 74, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: 27)
    }
}

