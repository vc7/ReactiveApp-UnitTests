//
//  TestScheduler+MarbleTests.swift
//  ReactiveApp
//
//  Created by SVYAT on 18.07.16.
//  Copyright © 2016 Svyatoslav Reshetnikov. All rights reserved.
//

import Foundation
import RxSwift
import RxTests
import RxCocoa

/**
 There are examples like this all over the web, but I think that I've first something like this here
 https://github.com/ReactiveX/RxJS/blob/master/doc/writing-marble-tests.md
 These tests are called marble tests.
 */
extension TestScheduler {
    /**
     Transformation from this format:
     
     ---a---b------c-----
     
     to this format
     
     schedule onNext(1) @ 0.6s
     schedule onNext(2) @ 1.4s
     schedule onNext(3) @ 7.0s
     ....
     ]
     
     You can also specify retry data in this format:
     
     ---a---b------c----#|----a--#|----b
     - letters and digits mark values
     - `#` marks unknown error
     - `|` marks sequence completed
     */
    func parseEventsAndTimes<T>(timeline: String, values: [String: T], errors: [String: ErrorType] = [:]) -> [[Recorded<Event<T>>]] {
        //print("parsing: \(timeline)")
        typealias RecordedEvent = Recorded<Event<T>>
        let timelines = timeline.componentsSeparatedByString("|")
        
        let allExceptLast = timelines[0 ..< timelines.count - 1]
        
        return (allExceptLast.map { $0 + "|" } + [timelines.last!])
            .filter { $0.characters.count > 0 }
            .map { timeline -> [Recorded<Event<T>>] in
                let segments = timeline.componentsSeparatedByString("-")
                let (time: _, events: events) = segments.reduce((time: 0, events: [RecordedEvent]())) { state, event in
                    let tickIncrement = event.characters.count + 1
                    
                    if event.characters.count == 0 {
                        return (state.time + tickIncrement, state.events)
                    }
                    
                    if event == "#" {
                        let errorEvent = RecordedEvent(time: state.time, event: Event<T>.Error(NSError(domain: "Any error domain", code: -1, userInfo: nil)))
                        return (state.time + tickIncrement, state.events + [errorEvent])
                    }
                    
                    if event == "|" {
                        let completed = RecordedEvent(time: state.time, event: Event<T>.Completed)
                        return (state.time + tickIncrement, state.events + [completed])
                    }
                    
                    guard let next = values[event] else {
                        guard let error = errors[event] else {
                            fatalError("Value with key \(event) not registered as value:\n\(values)\nor error:\n\(errors)")
                        }
                        
                        let nextEvent = RecordedEvent(time: state.time, event: Event<T>.Error(error))
                        return (state.time + tickIncrement, state.events + [nextEvent])
                    }
                    
                    let nextEvent = RecordedEvent(time: state.time, event: Event<T>.Next(next))
                    return (state.time + tickIncrement, state.events + [nextEvent])
                }
                
                //print("parsed: \(events)")
                return events
        }
    }
    
    /**
     Creates driver for marble test.
     - parameter timeline: Timeline in the form `---a---b------c--|`
     - parameter values: Dictionary of values in timeline. `[a:1, b:2]`
     - returns: Driver specified by timeline and values.
     */
    func createDriver<T>(timeline: String, values: [String: T]) -> Driver<T> {
        return createObservable(timeline, values: values, errors: [:]).asDriver(onErrorRecover: { (error) -> Driver<T> in
            //fatalError("This can't error out")
            return Driver.never()
        })
    }
    
    /**
     Creates observable for marble tests.
     
     - parameter timeline: Timeline in the form `---a---b------c--|`
     - parameter values: Dictionary of values in timeline. `[a:1, b:2]`
     - parameter errors: Dictionary of errors in timeline.
     - returns: Observable sequence specified by timeline and values.
     */
    func createObservable<T>(timeline: String, values: [String: T], errors: [String: ErrorType] = [:]) -> Observable<T> {
        let events = self.parseEventsAndTimes(timeline, values: values, errors: errors)
        return createObservable(events)
    }
    
    /**
     Creates observable for marble tests.
     
     - parameter events: Recorded events to replay.
     - returns: Observable sequence specified by timeline and values.
     */
    func createObservable<T>(events: [Recorded<Event<T>>]) -> Observable<T> {
        return createObservable([events])
    }
    
    /**
     Creates observable for marble tests.
     
     - parameter events: Recorded events to replay. This overloads enables modeling of retries.
     `---a---b------c----#|----a--#|----b`
     When next observer is subscribed, next sequence will be replayed. If all sequences have
     been replayed and new observer is subscribed, `fatalError` will be raised.
     - returns: Observable sequence specified by timeline and values.
     */
    func createObservable<T>(events: [[Recorded<Event<T>>]]) -> Observable<T> {
        var attemptCount = 0
        print("created for \(events)")
        
        return Observable.create { observer in
            if attemptCount >= events.count {
                fatalError("This is attempt # \(attemptCount + 1), but timeline only allows \(events.count).\n\(events)")
            }
            
            let scheduledEvents = events[attemptCount].map { event in
                return self.scheduleRelative((), dueTime: resolution * NSTimeInterval(event.time)) { _ in
                    observer.on(event.value)
                    return  NopDisposable.instance
                }
            }
            
            attemptCount += 1
            
            return CompositeDisposable(disposables: scheduledEvents)
        }
    }
    
    /**
     Enables simple construction of mock implementations from marble timelines.
     - parameter Arg: Type of arguments of mocked method.
     - parameter Ret: Return type of mocked method. `Observable<Ret>`
     - parameter values: Dictionary of values in timeline. `[a:1, b:2]`
     - parameter errors: Dictionary of errors in timeline.
     - parameter timelineSelector: Method implementation. The returned string value represents timeline of
     returned observable sequence. `---a---b------c----#|----a--#|----b`
     - returns: Implementation of method that accepts arguments with parameter `Arg` and returns observable sequence
     with parameter `Ret`.
     */
    func mock<Arg, Ret>(values: [String: Ret], errors: [String: ErrorType] = [:], timelineSelector: Arg -> String) -> Arg -> Observable<Ret> {
        return { (parameters: Arg) -> Observable<Ret> in
            let timeline = timelineSelector(parameters)
            
            return self.createObservable(timeline, values: values, errors: errors)
        }
    }
    
    /**
     Builds testable observer for s specific observable sequence, binds it's results and sets up disposal.
     
     - parameter source: Observable sequence to observe.
     - returns: Observer that records all events for observable sequence.
     */
    func record<O: ObservableConvertibleType>(source: O) -> TestableObserver<O.E> {
        let observer = self.createObserver(O.E.self)
        let disposable = source.asObservable().bindTo(observer)
        self.scheduleAt(100000) {
            disposable.dispose()
        }
        return observer
    }
}