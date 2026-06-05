// 画像の余白を自動トリミングして正方形パディング付きで保存する
// 使い方: swift trim_icon.swift input.png output.png [padding_ratio]
//   padding_ratio: コンテンツに対する余白の比率（デフォルト 0.08 = 8%）

import Foundation
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("Usage: swift trim_icon.swift input.png output.png [padding_ratio]"); exit(1)
}
let inputPath = args[1]
let outputPath = args[2]
let paddingRatio: CGFloat = args.count >= 4 ? CGFloat(Double(args[3]) ?? 0.08) : 0.08

guard let image = NSImage(contentsOfFile: inputPath),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("❌ 画像読み込み失敗: \(inputPath)"); exit(1)
}
let w = cg.width, h = cg.height
print("入力: \(w)×\(h)")

let colorSpace = CGColorSpaceCreateDeviceRGB()
let bytesPerRow = w * 4
let totalBytes = h * bytesPerRow

// 1) ヒープ上にバッファを確保して 0xFF（白）で初期化
let bufferPtr = UnsafeMutableRawPointer.allocate(byteCount: totalBytes, alignment: 1)
defer { bufferPtr.deallocate() }
memset(bufferPtr, 0xFF, totalBytes)

let bgBitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
guard let bgCtx = CGContext(data: bufferPtr,
                            width: w, height: h,
                            bitsPerComponent: 8,
                            bytesPerRow: bytesPerRow,
                            space: colorSpace,
                            bitmapInfo: bgBitmapInfo) else {
    print("❌ CGContext 作成失敗"); exit(1)
}
bgCtx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

// 2) バッファをバイト列として読み出す
let bytes = bufferPtr.bindMemory(to: UInt8.self, capacity: totalBytes)

func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    let off = y * bytesPerRow + x * 4
    return (Int(bytes[off]), Int(bytes[off+1]), Int(bytes[off+2]))
}

// 3) 背景色は白固定（icon-source は白背景なので。アルファ透明部分も白に合成済み）
//    隅の方が10%以上"白以外"だったら判定が乱れる可能性があるので、参考表示のみ
let cornerSamples = [pixel(0,0), pixel(w-1,0), pixel(0,h-1), pixel(w-1,h-1)]
print("隅のサンプル色: \(cornerSamples)")
let bgR = 255, bgG = 255, bgB = 255
print("背景色（白固定）: R=\(bgR) G=\(bgG) B=\(bgB)")

// 4) 各ピクセルが背景（白）と十分違うか
//    背景から±25 程度の差は誤差として無視。それ以上のずれをコンテンツと判定
let threshold = 60   // RGB 各成分の差の合計
func isContent(_ p: (r: Int, g: Int, b: Int)) -> Bool {
    return abs(p.r - bgR) + abs(p.g - bgG) + abs(p.b - bgB) > threshold
}

// 5) バウンディングボックス
var minX = w, minY = h, maxX = -1, maxY = -1
for y in 0..<h {
    for x in 0..<w {
        if isContent(pixel(x, y)) {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
}
guard maxX > minX, maxY > minY else {
    print("❌ コンテンツが見つかりませんでした"); exit(1)
}
let contentW = maxX - minX + 1
let contentH = maxY - minY + 1
print("コンテンツ範囲: x=\(minX)…\(maxX) y=\(minY)…\(maxY) → \(contentW)×\(contentH)")

// 6) 余白を付けて正方形パディング
let contentSide = max(contentW, contentH)
let padding = Int(CGFloat(contentSide) * paddingRatio)
let side = contentSide + padding * 2
let centerX = (minX + maxX) / 2
let centerY = (minY + maxY) / 2
print("出力サイズ: \(side)×\(side)（余白率 \(paddingRatio)）")

// 7) 出力（元画像の透過情報を保ったまま中央配置）
let outBitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
guard let outCtx = CGContext(data: nil,
                             width: side, height: side,
                             bitsPerComponent: 8,
                             bytesPerRow: side * 4,
                             space: colorSpace,
                             bitmapInfo: outBitmapInfo) else {
    print("❌ 出力 CGContext 作成失敗"); exit(1)
}
// CG 座標は左下原点なので Y を反転
let drawX = -(centerX - side/2)
let drawY = -(((h - 1) - centerY) - side/2)
outCtx.draw(cg, in: CGRect(x: drawX, y: drawY, width: w, height: h))

guard let outCG = outCtx.makeImage() else { print("❌ 画像生成失敗"); exit(1) }
let rep = NSBitmapImageRep(cgImage: outCG)
guard let pngData = rep.representation(using: .png, properties: [:]) else {
    print("❌ PNG エンコード失敗"); exit(1)
}
try pngData.write(to: URL(fileURLWithPath: outputPath))
print("✅ 出力: \(outputPath)")
