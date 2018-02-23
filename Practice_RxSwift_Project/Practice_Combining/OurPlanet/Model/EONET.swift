/*
 * Copyright (c) 2016 Razeware LLC
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */


import Foundation
import RxSwift
import RxCocoa

class EONET {
    static let API = "https://eonet.sci.gsfc.nasa.gov/api/v2.1"
    static let categoriesEndpoint = "/categories"
    static let eventsEndpoint = "/events"

    static var ISODateReader: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZ"
        return formatter
    }()

    static var categories: Observable<[EOCategory]> = {
        //fetch categories
       return EONET.request(endpoint: categoriesEndpoint)
        .map{ data in
            let categories = data["categories"] as? [[String: Any]] ?? []

            //map the categories array to EOCategory objects and sort them by the name
            return categories.flatMap(EOCategory.init)
                .sorted { $0.name < $1.name}
        }
        .catchErrorJustReturn([])
        .share(replay: 1, scope: .forever)
        //using share relays all elements to the first subscriber
        //then replays the last received element to any new subscriber without re-requesting the data. act like cache(the purpose of .forever lifetime scope)
    }()

    static func filteredEvents(events: [EOEvent], forCategory category: EOCategory) -> [EOEvent] {
        return events.filter { event in
            return event.categories.contains(category.id) &&
                !category.events.contains {
                    $0.id == event.id
            }
            }
            .sorted(by: EOEvent.compareDates)
    }

    static func request(endpoint: String, query: [String: Any] = [:]) -> Observable<[String: Any]> {
        //Generic request
        do {
            guard let url = URL(string: API)?.appendingPathComponent(endpoint),
                var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
                    throw EOError.invalidURL(endpoint)
            }

            components.queryItems = try query.flatMap{ (key, value) in
                guard let v = value as? CustomStringConvertible else {
                    throw EOError.invalidParameter(key, value)
                }
                return URLQueryItem(name: key, value: v.description)
            }

            guard let finalURL = components.url else {
                throw EOError.invalidURL(endpoint)
            }

            let request = URLRequest(url: finalURL)

            return URLSession.shared.rx.response(request: request)
                .map{ _, data -> [String: Any] in
                    guard let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
                        let result = jsonObject as? [String: Any] else {
                            throw EOError.invalidJSON(finalURL.absoluteString)
                    }
                    return result
            }
        } catch {
            return Observable.empty()
        }
    }

    static func events(forLast days: Int = 360) -> Observable<[EOEvent]> {
        let openEvents = events(forLast: days, closed: false)
        let closedEvents = events(forLast: days, closed: true)

        //emit the open and then closed
        //start with empty array, each time one observables delivers, called it
        //once completed, reduce emits a single value (current state) and completes
        return Observable.of(openEvents, closedEvents)
            .merge()
            .reduce([]) { running, new in
                running + new
        }
    }

    fileprivate static func events(forLast days: Int, closed: Bool) -> Observable<[EOEvent]> {
        //decode json
        return request(endpoint: eventsEndpoint, query: [
            "days": NSNumber(value: days),
            "status": (closed ? "closed" : "open")
            ])
            .map { json in
                guard let raw = json["events"] as? [[String: Any]] else {
                    throw EOError.invalidJSON(eventsEndpoint)
                }
                return raw.flatMap(EOEvent.init)
            }
            .catchErrorJustReturn([])
    }
}
