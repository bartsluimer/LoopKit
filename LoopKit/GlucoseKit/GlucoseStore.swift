//
//  GlucoseStore.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 1/24/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import Foundation
import CoreData
import HealthKit
import os.log


public enum GlucoseStoreResult<T> {
    case success(T)
    case failure(Error)
}


extension NSNotification.Name {
    /// Notification posted when glucose samples were changed, either via add/replace/delete methods or from HealthKit
    public static let GlucoseSamplesDidChange = NSNotification.Name(rawValue: "com.loopkit.GlucoseStore.GlucoseSamplesDidChange")
}


/**
 Manages storage, retrieval, and calculation of glucose data.
 
 There are three tiers of storage:
 
 * Short-term persistant cache, stored in Core Data, used to ensure access if the app is suspended and re-launched while the Health database is protected
```
 0    [max(momentumDataInterval, cacheLength)]
 |––––|
```
 * HealthKit data, managed by the current application
```
 0    [managedDataInterval?]
 |––––––––––––|
```
 * HealthKit data, managed by the manufacturer's application
```
      [managedDataInterval?]           [maxPurgeInterval]
              |–––––––––--->
```
 */
public final class GlucoseStore: HealthKitSampleStore {

    private let glucoseType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose)!

    /// The oldest interval to include when purging managed data
    private let maxPurgeInterval: TimeInterval = TimeInterval(hours: 24) * 7

    /// The interval before which glucose values should be purged from HealthKit. If nil, glucose values are not purged.
    public var managedDataInterval: TimeInterval? {
        get {
            return lockedManagedDataInterval.value
        }
        set {
            lockedManagedDataInterval.value = newValue
        }
    }
    private let lockedManagedDataInterval = Locked<TimeInterval?>(.hours(3))

    /// The interval of glucose data to keep in cache
    public let cacheLength: TimeInterval

    /// The interval of glucose data to use for momentum calculation
    public let momentumDataInterval: TimeInterval

    private let dataAccessQueue = DispatchQueue(label: "com.loudnate.GlucoseKit.dataAccessQueue", qos: .utility)

    private let log = OSLog(category: "GlucoseStore")

    /// The most-recent glucose value.
    public private(set) var latestGlucose: GlucoseValue? {
        get {
            return lockedLatestGlucose.value
        }
        set {
            lockedLatestGlucose.value = newValue
        }
    }
    private let lockedLatestGlucose = Locked<GlucoseValue?>(nil)

    public let cacheStore: PersistenceController

    public init(
        healthStore: HKHealthStore,
        cacheStore: PersistenceController,
        cacheLength: TimeInterval = 60 /* minutes */ * 60 /* seconds */,
        momentumDataInterval: TimeInterval = 15 /* minutes */ * 60 /* seconds */
    ) {
        self.cacheStore = cacheStore
        self.momentumDataInterval = momentumDataInterval
        self.cacheLength = max(cacheLength, momentumDataInterval)

        super.init(healthStore: healthStore, type: glucoseType, observationStart: Date(timeIntervalSinceNow: -cacheLength))

        cacheStore.onReady { [unowned self] (error) in
            self.dataAccessQueue.async {
                self.updateLatestGlucose()
            }
        }
    }

    // MARK: - HealthKitSampleStore

    override func processResults(from query: HKAnchoredObjectQuery, added: [HKSample], deleted: [HKDeletedObject], error: Error?) {
        guard error == nil else {
            return
        }

        dataAccessQueue.async {
            var notificationRequired = false

            // Added samples
            let samples = (added as? [HKQuantitySample]) ?? []
            if self.addCachedObjects(for: samples.filterDateRange(self.earliestCacheDate, nil)) {
                notificationRequired = true
            }

            // Deleted samples
            for sample in deleted {
                if self.deleteCachedObject(forSampleUUID: sample.uuid) {
                    notificationRequired = true
                }
            }

            if notificationRequired {
                self.purgeOldGlucoseSamples()
                self.updateLatestGlucose()

                NotificationCenter.default.post(name: .GlucoseSamplesDidChange, object: self, userInfo: [GlucoseStore.notificationUpdateSourceKey: UpdateSource.queriedByHealthKit.rawValue])
            }
        }
    }
}

extension GlucoseStore {
    /// Add new glucose values to HealthKit.
    ///
    /// This operation is performed asynchronously and the completion will be executed on an arbitrary background queue.
    ///
    /// - Parameters:
    ///   - glucose: A glucose sample to save
    ///   - completion: A closure called after the save completes
    ///   - result: The saved glucose value
    public func addGlucose(_ glucose: NewGlucoseSample, completion: @escaping (_ result: GlucoseStoreResult<GlucoseValue>) -> Void) {
        addGlucose([glucose]) { (result) in
            switch result {
            case .success(let values):
                completion(.success(values.first!))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Add new glucose values to HealthKit.
    ///
    /// This operation is performed asynchronously and the completion will be executed on an arbitrary background queue.
    ///
    /// - Parameters:
    ///   - values: An array of glucose samples to save
    ///   - completion: A closure called after the save completes
    ///   - result: The saved glucose values
    public func addGlucose(_ values: [NewGlucoseSample], completion: @escaping (_ result: GlucoseStoreResult<[GlucoseValue]>) -> Void) {
        guard values.count > 0 else {
            completion(.success([]))
            return
        }

        let glucose = values.map { value -> HKQuantitySample in
            let metadata: [String: Any] = [
                MetadataKeyGlucoseIsDisplayOnly: value.isDisplayOnly,
                HKMetadataKeySyncIdentifier: value.syncIdentifier,
                HKMetadataKeySyncVersion: 1,
            ]

            return HKQuantitySample(
                type: glucoseType,
                quantity: value.quantity,
                start: value.date,
                end: value.date,
                device: value.device,
                metadata: metadata
            )
        }

        healthStore.save(glucose) { (completed, error) in
            self.dataAccessQueue.async {
                if let error = error {
                    completion(.failure(error))
                } else if completed {
                    self.addCachedObjects(for: glucose)
                    self.purgeOldGlucoseSamples()
                    self.updateLatestGlucose()

                    completion(.success(glucose))
                    NotificationCenter.default.post(name: .GlucoseSamplesDidChange, object: self, userInfo: [GlucoseStore.notificationUpdateSourceKey: UpdateSource.changedInApp.rawValue])
                } else {
                    assertionFailure()
                }
            }
        }
    }

    /**
     Cleans the in-memory and HealthKit caches.
     
     *This method should only be called from the `dataAccessQueue`*
     */
    private func purgeOldGlucoseSamples() {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        let cachePredicate = NSPredicate(format: "startDate < %@", earliestCacheDate as NSDate)
        purgeCachedGlucoseObjects(matching: cachePredicate)

        if let managedDataInterval = managedDataInterval {
            let predicate = HKQuery.predicateForSamples(withStart: Date(timeIntervalSinceNow: -maxPurgeInterval), end: Date(timeIntervalSinceNow: -managedDataInterval), options: [])

            healthStore.deleteObjects(of: glucoseType, predicate: predicate) { (success, count, error) -> Void in
                // error is expected and ignored if protected data is unavailable
                // TODO: Send this to the delegate
            }
        }
    }

    private func getCachedGlucoseSamples(start: Date, end: Date? = nil, completion: @escaping (_ samples: [StoredGlucoseSample]) -> Void) {
        getGlucoseSamples(start: start, end: end) { (result) in
            switch result {
            case .success(let samples):
                completion(samples)
            case .failure:
                completion(self.getCachedGlucoseSamples().filterDateRange(start, end))
            }
        }
    }

    private func getGlucoseSamples(start: Date, end: Date? = nil, completion: @escaping (_ result: GlucoseStoreResult<[StoredGlucoseSample]>) -> Void) {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let sortDescriptors = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]

        let query = HKSampleQuery(sampleType: glucoseType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: sortDescriptors) { (_, samples, error) -> Void in

            self.dataAccessQueue.async {
                if let error = error {
                    completion(.failure(error))
                } else {
                    let samples = samples as? [HKQuantitySample] ?? []
                    completion(.success(samples.map { StoredGlucoseSample(sample: $0) }))
                }
            }
        }

        healthStore.execute(query)
    }

    /// Retrieves glucose values from HealthKit within the specified date range
    ///
    /// - Parameters:
    ///   - start: The earliest date of values to retrieve
    ///   - end: The latest date of values to retrieve, if provided
    ///   - completion: A closure called once the values have been retrieved
    ///   - result: An array of glucose values, in chronological order by startDate
    public func getGlucoseValues(start: Date, end: Date? = nil, completion: @escaping (_ result: GlucoseStoreResult<[StoredGlucoseSample]>) -> Void) {
        getGlucoseSamples(start: start, end: end) { (result) -> Void in
            switch result {
            case .success(let samples):
                completion(.success(samples))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Retrieves glucose values from either HealthKit or the in-memory cache.
    ///
    /// - Parameters:
    ///   - start: The earliest date of values to retrieve
    ///   - end: The latest date of values to retrieve, if provided
    ///   - completion: A closure called once the values have been retrieved
    ///   - values: An array of glucose values, in chronological order by startDate
    public func getCachedGlucoseValues(start: Date, end: Date? = nil, completion: @escaping (_ values: [StoredGlucoseSample]) -> Void) {
        getCachedGlucoseSamples(start: start, end: end) { (samples) in
            completion(samples)
        }
    }
}


// MARK: - Core Data
extension NSManagedObjectContext {
    fileprivate func cachedGlucoseObjectsWithUUID(_ uuid: UUID, fetchLimit: Int? = nil) -> [CachedGlucoseObject] {
        let request: NSFetchRequest<CachedGlucoseObject> = CachedGlucoseObject.fetchRequest()
        if let limit = fetchLimit {
            request.fetchLimit = limit
        }
        request.predicate = NSPredicate(format: "uuid == %@", uuid as NSUUID)

        return (try? fetch(request)) ?? []
    }
}

extension GlucoseStore {
    @discardableResult
    private func addCachedObject(for sample: HKQuantitySample) -> Bool {
        return addCachedObjects(for: [sample])
    }

    @discardableResult
    private func addCachedObjects(for samples: [HKQuantitySample]) -> Bool {
        return addCachedObjects(for: samples.map { StoredGlucoseSample(sample: $0) })
    }

    /// Creates new cached glucose objects from samples if they're not already cached
    ///
    /// - Parameter samples: The samples to cache
    /// - Returns: Whether new cached objects were created
    @discardableResult
    private func addCachedObjects(for samples: [StoredGlucoseSample]) -> Bool {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        var created = false

        cacheStore.managedObjectContext.performAndWait {
            for sample in samples {
                guard self.cacheStore.managedObjectContext.cachedGlucoseObjectsWithUUID(sample.sampleUUID, fetchLimit: 1).count == 0 else {
                    continue
                }

                let object = CachedGlucoseObject(context: self.cacheStore.managedObjectContext)
                object.update(from: sample)
                created = true
            }

            if created {
                do {
                    try self.cacheStore.managedObjectContext.save()
                } catch let error {
                    self.log.error("Unable to save new cached objects: %@", String(describing: error))
                }
            }
        }

        return created
    }

    /// Fetches glucose samples from the cache that match the given predicate
    ///
    /// - Parameter predicate: The predicate to apply to the objects
    /// - Returns: An array of glucose samples, in chronological order by startDate
    private func getCachedGlucoseSamples(matching predicate: NSPredicate? = nil) -> [StoredGlucoseSample] {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        var samples: [StoredGlucoseSample] = []

        cacheStore.managedObjectContext.performAndWait {
            let request: NSFetchRequest<CachedGlucoseObject> = CachedGlucoseObject.fetchRequest()
            request.predicate = predicate
            request.sortDescriptors = [NSSortDescriptor(key: "startDate", ascending: true)]

            do {
                let objects = try self.cacheStore.managedObjectContext.fetch(request)
                samples = objects.map { StoredGlucoseSample(managedObject: $0) }
            } catch let error {
                self.log.error("Error fetching CachedGlucoseSamples: %@", String(describing: error))
            }
        }

        return samples
    }

    private func updateLatestGlucose() {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        cacheStore.managedObjectContext.performAndWait {
            let request: NSFetchRequest<CachedGlucoseObject> = CachedGlucoseObject.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "startDate", ascending: false)]
            request.fetchLimit = 1

            do {
                let objects = try self.cacheStore.managedObjectContext.fetch(request)

                if let lastObject = objects.first {
                    self.latestGlucose = StoredGlucoseSample(managedObject: lastObject)
                }
            } catch let error {
                self.log.error("Unable to fetch latest glucose object: %@", String(describing: error))
            }
        }
    }

    private func deleteCachedObject(forSampleUUID uuid: UUID) -> Bool {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        var deleted = false

        cacheStore.managedObjectContext.performAndWait {
            for object in self.cacheStore.managedObjectContext.cachedGlucoseObjectsWithUUID(uuid) {

                self.cacheStore.managedObjectContext.delete(object)
                deleted = true
            }

            if deleted {
                do {
                    try self.cacheStore.managedObjectContext.save()
                } catch let error {
                    self.log.error("Unable to save deleted CachedGlucoseObjects: %@", String(describing: error))
                }
            }
        }

        return deleted
    }

    private var earliestCacheDate: Date {
        return Date(timeIntervalSinceNow: -cacheLength)
    }

    private func purgeCachedGlucoseObjects(matching predicate: NSPredicate) {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        cacheStore.managedObjectContext.performAndWait {
            let fetchRequest: NSFetchRequest<NSFetchRequestResult> = CachedGlucoseObject.fetchRequest()
            fetchRequest.predicate = predicate

            let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
            deleteRequest.resultType = .resultTypeObjectIDs

            do {
                let result = try cacheStore.managedObjectContext.execute(deleteRequest)
                if  let deleteResult = result as? NSBatchDeleteResult,
                    let objectIDs = deleteResult.result as? [NSManagedObjectID]
                {
                    self.log.info("Deleted %d CachedGlucoseObjects", objectIDs.count)

                    if objectIDs.count > 0 {
                        let changes = [NSDeletedObjectsKey: objectIDs]
                        NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [cacheStore.managedObjectContext])
                        cacheStore.managedObjectContext.refreshAllObjects()
                    }
                }
            } catch let error {
                self.log.error("Unable to purge CachedGlucoseObjects: %@", String(describing: error))
            }
        }
    }
}


// MARK: - Math
extension GlucoseStore {
    /**
     Calculates the momentum effect for recent glucose values

     The duration of effect data returned is determined by the `momentumDataInterval`, and the delta between data points is 5 minutes.

     This operation is performed asynchronously and the completion will be executed on an arbitrary background queue.

     - Parameters:
        - completion: A closure called once the calculation has completed. The closure takes two arguments:
        - effects: The calculated effect values, or an empty array if the glucose data isn't suitable for momentum calculation.
     */
    public func getRecentMomentumEffect(_ completion: @escaping (_ effects: [GlucoseEffect]) -> Void) {
        getCachedGlucoseSamples(start: Date(timeIntervalSinceNow: -momentumDataInterval)) { (samples) in
            let effects = samples.linearMomentumEffect(
                duration: self.momentumDataInterval,
                delta: TimeInterval(minutes: 5)
            )
            completion(effects)
        }
    }

    /// Calculates the a change in glucose values between the specified date interval.
    /// 
    /// Values within the date interval must not include a calibration, and the returned change 
    /// values will be from the same source.
    ///
    /// - Parameters:
    ///   - start: The earliest date to include. The earliest supported date when the Health database is unavailable is determined by `cacheLength`.
    ///   - end: The latest date to include
    ///   - completion: A closure called once the calculation has completed
    ///   - change: A tuple of the first and last glucose values describing the change, if computable.
    public func getGlucoseChange(start: Date, end: Date? = nil, completion: @escaping (_ change: (GlucoseValue, GlucoseValue)?) -> Void) {
        getCachedGlucoseSamples(start: start, end: end) { (samples) in
            let change: (GlucoseValue, GlucoseValue)?

            if let provenanceIdentifier = samples.last?.provenanceIdentifier {
                // Enforce a single source
                let samples = samples.filterAfterCalibration().filter { $0.provenanceIdentifier == provenanceIdentifier }

                if samples.count > 1,
                    let first = samples.first,
                    let last = samples.last,
                    first.startDate < last.startDate
                {
                    change = (first, last)
                } else {
                    change = nil
                }
            } else {
                change = nil
            }

            completion(change)
        }
    }

    /// Calculates a timeline of effect velocity (glucose/time) observed in glucose that counteract the specified effects.
    ///
    /// - Parameters:
    ///   - start: The earliest date of glucose values to include
    ///   - end: The latest date of glucose values to include, if provided
    ///   - effects: Glucose effects to be countered, in chronological order
    ///   - completion: A closure called once the values have been retrieved
    ///   - effects: An array of velocities describing the change in glucose samples compared to the specified effects
    public func getCounteractionEffects(start: Date, end: Date? = nil, to effects: [GlucoseEffect], _ completion: @escaping (_ effects: [GlucoseEffectVelocity]) -> Void) {
        getCachedGlucoseSamples(start: start, end: end) { (samples) in
            completion(samples.counteractionEffects(to: effects))
        }
    }
}

extension GlucoseStore {
    /// Generates a diagnostic report about the current state
    ///
    /// This operation is performed asynchronously and the completion will be executed on an arbitrary background queue.
    ///
    /// - parameter completionHandler: A closure called once the report has been generated. The closure takes a single argument of the report string.
    public func generateDiagnosticReport(_ completionHandler: @escaping (_ report: String) -> Void) {
        dataAccessQueue.async {
            var report: [String] = [
                "## GlucoseStore",
                "",
                "* latestGlucoseValue: \(String(reflecting: self.latestGlucose))",
                "* managedDataInterval: \(self.managedDataInterval ?? 0)",
                "* cacheLength: \(self.cacheLength)",
                "* momentumDataInterval: \(self.momentumDataInterval)",
                super.debugDescription,
                "",
                "### cachedGlucoseSamples",
            ]

            for sample in self.getCachedGlucoseSamples() {
                report.append(String(describing: sample))
            }

            report.append("")

            completionHandler(report.joined(separator: "\n"))
        }
    }
}
