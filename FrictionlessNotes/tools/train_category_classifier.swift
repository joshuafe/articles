//
//  train_category_classifier.swift
//  FrictionlessNotes — Stage-1 ANE first pass
//
//  Trains a Create ML text classifier (transcript → NoteCategory) and writes
//  NoteCategoryClassifier.mlmodel next to this script. Xcode compiles that to a
//  .mlmodelc that CategoryFirstPass loads on-device (Neural Engine).
//
//  Run from the tools/ directory on macOS (needs Xcode):
//      cd tools && xcrun swift train_category_classifier.swift
//
//  The seed data here is synthetic; the real signal is free and arrives later —
//  Gemma's own category decisions plus the user's corrections become labels we
//  append to category_training_data.json and retrain on.
//

import Foundation
import CreateML

let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let dataURL = cwd.appendingPathComponent("category_training_data.json")
let outURL = cwd.appendingPathComponent("NoteCategoryClassifier.mlmodel")

print("Loading \(dataURL.lastPathComponent) …")
let table = try MLDataTable(contentsOf: dataURL)
print("  \(table.rows.count) rows, columns: \(table.columnNames)")

// Hold out a slice for an honest accuracy read.
let (trainTable, testTable) = table.randomSplit(by: 0.85, seed: 7)

print("Training MLTextClassifier (\(trainTable.rows.count) train / \(testTable.rows.count) held out) …")
let classifier = try MLTextClassifier(trainingData: trainTable,
                                      textColumn: "text",
                                      labelColumn: "label")

func pct(_ error: Double) -> String { String(format: "%.1f%%", (1.0 - error) * 100) }
print("  training accuracy:   \(pct(classifier.trainingMetrics.classificationError))")
print("  validation accuracy: \(pct(classifier.validationMetrics.classificationError))")

let eval = classifier.evaluation(on: testTable, textColumn: "text", labelColumn: "label")
print("  held-out accuracy:   \(pct(eval.classificationError))")

let metadata = MLModelMetadata(
    author: "FrictionlessNotes",
    shortDescription: "Stage-1 note category first pass (todo/shopping/idea/note/journal/reference)",
    version: "1.0")
try classifier.write(to: outURL, metadata: metadata)
print("Wrote \(outURL.lastPathComponent)")
