//
//  ScoreParser.swift
//  Metronome
//
//  Created by James Bean on 5/30/17.
//  Copyright © 2017 James Bean. All rights reserved.
//

import Foundation
import ArithmeticTools
import Rhythm

class ScoreParser {
    
    /// Things that can go wrong when parsing a score.
    enum Error: Swift.Error {
        case illFormedScore(Any)
        case illFormedScoreElement(Any)
        case illFormedMeter(String)
        case illFormedTempo(Any)
    }

    /// Creates `Meter` value with the given `string`. 
    ///
    /// The string must be in the format: `beats / subdivision`.
    ///
    ///     3/4 -> Meter(3,4)
    ///     12/13 -> fatalError
    ///     3,4 -> Error.illFormedMeter
    ///
    ///
    /// - Returns: Meter value
    /// - Throws: ScoreParser.Error
    /// - Warning: The Meter initializer will crash if given a non-power-of-two subdivision.
    static func parseMeter(_ string: String) throws -> Meter {
        
        let components = string.components(separatedBy: "/")
        
        guard
            let beatsString = components[safe: 0],
            let subdivisionString = components[safe: 1],
            let beats = Int(beatsString),
            let subdivision = Int(subdivisionString)
        else {
            throw Error.illFormedMeter(string)
        }
        
        return Meter(beats, subdivision)
    }
    
    static func extractMeter(from yaml: [String: Any]) -> Meter? {
        
        for (key, _) in yaml {
            if let meter = try? parseMeter(key) {
                return meter
            }
        }
        
        return nil
    }
    
    private var meterOffset: MetricalDuration = .zero
    
    /// Meters to be created during the parsing process
    internal var meters: [Meter] = []
    
    /// Builder to create the tempo stratum
    internal var tempoStratumBuilder = Tempo.Stratum.Builder()
    
    /// Data to be parsed
    private let score: [Any]
    
    // MARK: - Initializers
    
    /// Creates a `ScoreParser` with the given `yaml` structure.
    ///
    /// - Throws: ScoreParser.Error if the given `yaml` is not a `[Any]`.
    ///
    public init(yaml: Any) throws {
        
        guard let yamlScore = yaml as? [Any] else {
            throw Error.illFormedScore(yaml)
        }

        self.score = yamlScore
    }
    
    private func prepare() {
        meterOffset = .zero
        meters = []
        tempoStratumBuilder = Tempo.Stratum.Builder()
    }
    
    func parse() throws -> Meter.Structure {

        prepare()
        try score.forEach(parseScoreElement)

        let tempoStratum = tempoStratumBuilder.build()
        
        print(tempoStratumBuilder)
        
        return Meter.Structure(meters: meters, tempi: tempoStratum)
    }
    
    func parseScoreElement(_ yaml: Any) throws {
        
        if let meter = yaml as? String {
            
            // Either meter: 4/4, or
            // 4/4 x 8
            try parseMeterOneOrMany(meter)
            
        } else if let scoreElementWithAttributes = yaml as? [String: Any] {
            try parseScoreElementWithAttributes(scoreElementWithAttributes)
            
        } else {
            throw Error.illFormedScoreElement(yaml)
        }
    }
    
    func parseScoreElementWithAttributes(_ yaml: [String: Any]) throws {
        
        guard let meter = ScoreParser.extractMeter(from: yaml) else {
            throw Error.illFormedScoreElement(yaml)
        }

        var tempoChanges: [(Tempo, MetricalDuration, Bool)] = []
        
        print(yaml)

        for (key, value) in yaml {
            
            print("key: \(key); value: \(value)")
            
            switch key {
            case "tempo", "tempo_change":
                
                var bpm: Double? {
                    switch value {
                    case let double as Double:
                        return double
                    case let float as Float:
                        return Double(float)
                    case let int as Int:
                        return Double(int)
                    case let string as String:
                        return Double(string)
                    default:
                        return nil
                    }
                }
                
                guard let beatsPerMinute = bpm else {
                    throw Error.illFormedScoreElement(yaml)
                }
                
                let tempo = Tempo(beatsPerMinute, subdivision: meter.denominator)
                let interpolating = key == "tempo_change"
                
                tempoChanges.append((tempo, meterOffset, interpolating))

            default:
                break
            }
            
            if let offsetAttributes = value as? [[String: Any]] {
                print("offset attr: \(offsetAttributes)")
                
                // FIXME: Manage duplication here
                
                for offsetAttribute in offsetAttributes {
                    
                    var beatOffset: MetricalDuration = .zero
                    var tempo: Tempo?
                    var interpolation: Bool?
                    
                    for (key, val) in offsetAttribute {
                        switch key {
                        case "tempo", "tempo_change":
                
                            print("key: \(key) \(type(of: key)); value: \(val) \(type(of: val)); ")
                            
                            var bpm: Double? {
                                switch val {
                                case let double as Double:
                                    return double
                                case let float as Float:
                                    return Double(float)
                                case let int as Int:
                                    return Double(int)
                                case let string as String:
                                    return Double(string)
                                default:
                                    return nil
                                }
                            }
                            
                            guard let beatsPerMinute = bpm else {
                                print("bad bpm: \(bpm)")
                                throw Error.illFormedScoreElement(yaml)
                            }
                            
                            tempo = Tempo(beatsPerMinute, subdivision: meter.denominator)
                            interpolation = key == "tempo_change"

                            print("tempo: \(val)")
                        default:
                            
                            // try meter
                            if let meter = try? ScoreParser.parseMeter(key) {
                                beatOffset = meter.metricalDuration
                            } else if let beats = Int(key) {
                                print("Beats: \(beats)")
                                beatOffset = MetricalDuration(beats, meter.denominator)
                            }
                            
                            break
                        }
                    }
                    
                    if let tempo = tempo, let interpolation = interpolation {
                        tempoChanges.append((tempo, meterOffset + beatOffset, interpolation))
                    }
                }
            }
        }
        
        print("tempo changes: \(tempoChanges)")
        
        tempoChanges.forEach { tempo, offset, interpolating in
            add(tempo: tempo, at: offset, interpolating: interpolating)
        }

        print("meter: \(meter)")
        add(meter: meter)
    }
    
    func parseMeterOneOrMany(_ string: String) throws {
        
        let components = string.components(separatedBy: " ")
        
        switch components.count {
        
        // Single meter, such as: 19/64
        case 1:
            add(meter: try ScoreParser.parseMeter(string))
            
        // Many meters, such as: 4/4 x 13
        case 3:
            
            let meter = try ScoreParser.parseMeter(components[0])
            
            guard let count = Int(components[2]) else {
                throw Error.illFormedMeter(string)
            }
            
            add(meter: meter, count: count)
            
        // Something went wrong
        default:
            throw Error.illFormedMeter(string)
        }
    }
    
    private func add(meter: Meter, count: Int = 1) {
        (0..<count).forEach { _ in
            self.meters.append(meter)
            self.meterOffset += meter.metricalDuration
        }
    }
    
    private func add(tempo: Tempo, at offset: MetricalDuration, interpolating: Bool) {
        tempoStratumBuilder.add(tempo, at: offset, interpolating: interpolating)
    }
}

