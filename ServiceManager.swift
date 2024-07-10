//
//  ServiceManager.swift
//  QuickLifts
//
//  Created by Tremaine Grant on 6/27/23.
//

import Foundation
import Combine
import AppTrackingTransparency
import AdSupport
import RevenueCat
import FirebaseAuth
import TipKit

// Service Manager
class ServiceManager: ObservableObject {
    // Initialize services
    var currentVersion = "1.32"
    var firebaseService = FirebaseService.sharedInstance
    var userService = UserService.sharedInstance
    var workoutService = WorkoutService.sharedInstance
    var notificationService = NotificationService.sharedInstance
    var gptService = GPTService.sharedInstance
    var exerciselogService = ExerciseLogService.sharedInstance
    var purchaseService = PurchaseService.sharedInstance
    var remoteConfigService = RemoteConfigService.sharedInstance
    let signInWithAppleService = AppleSignInService.sharedInstance
    let biometricSignature = BiometricSignatureService.sharedInstance
    let claudeService = ClaudeService.sharedInstance
    
    @Published var isConfigured = false
    @Published var registrationComplete = false
    @Published var isWorkoutInProgress = false
    @Published var isUILoaded = false
    @Published var workoutStartTime: Date?
    @Published var showTabBar = false
    @Published var isPremium = false
    static var isTesting = false
    
    private enum SubscriptionStatus: String {
        case subscribed = "Subscribed"
        case notSubscribed = "Not Subscribed"
    }
    
    @Published var subscriptionStatus = SubscriptionStatus.notSubscribed.rawValue
    
    func configure(u: User, isTesting: Bool? = false) async {
        if let testing = isTesting, testing == true {
            ServiceManager.isTesting = isTesting ?? false
            loadMockData()
            return
        }
        do {
            // Do any other configuration here
            if self.firebaseService.isAuthenticated {
                main {
                    self.purchaseService.subscribedPublisher
                        .map { isSubscribed -> String in
                            isSubscribed
                            ? SubscriptionStatus.subscribed.rawValue
                            : SubscriptionStatus.notSubscribed.rawValue
                        }.assign(to: &self.$subscriptionStatus)
                }
                                
                //Check if there is a workout in progress
                self.loadWorkoutProgressState()
                
                //Get all the remote config flags
                self.remoteConfigService.fetchRemoteConfig()
                
                WorkoutService.sharedInstance.cacheExercisesToQueue()
                
                UserService.sharedInstance.fetchFavoriteWorkouts { workouts, error in
                    print("done")
                }
                
                self.currentVersion = self.getAppVersion()
                
                UserService.sharedInstance.fetchFollowing { results in
                    switch results {
                    case .success(let followRequests):
                        UserService.sharedInstance.followsISent = followRequests
                    case .failure(let failure):
                        print(failure)
                    }
                }
                                
                if var updatedUser = UserService.sharedInstance.user {
                    if updatedUser.fcmToken == "" {
                        updatedUser.fcmToken = UserService.sharedInstance.fcmToken
                        UserService.sharedInstance.updateUser(user: updatedUser)
                    }
                }
                
                UserService.sharedInstance.getAllUsersByLocation(maxCount: 1000) { shortUsers, error in
                    print("fetched \(shortUsers?.count) users")
                }

                //get all the exercises
                self.workoutService.getExercises { result in
                    switch result {
                    case .success(let exercises):
//                        ExerciseAuditService.sharedInstance.auditExerciseBodyParts(exercises: exercises)
                        //How to approve a video that was denied
//                        if let ex = exercises.filter({ $0.id == "0D2E155C-37EB-4941-ADC6-E4DF8406C8EE"}).first {
//                            WorkoutService.sharedInstance.approveDeniedVideo(videoId: "47048996-E959-45DB-9BA2-EF420D5B31FC", exercise: ex)
//                        }
                        
//                        UserService.sharedInstance.updateFollowRequestProfileImage()
                        
                        //Fetch all the exercises users have liked.
                        UserService.sharedInstance.fetchLikedExercises { (liked, error) in
                            guard let liked = liked, error == nil else {
                                print("Error fetching favorites: \(error?.localizedDescription ?? "unknown error")")
                                return
                            }
                        }
                        
                        self.userService.fetchBodyWeights { bodyWeights, error in
                            print("Body Weights loaded \(bodyWeights)")
                            self.userService.user?.bodyWeight = bodyWeights ?? []
                        }
                        
                        let allExercises = exercises.map { $0.name }
                        
                        ExerciseLogService.sharedInstance.fetchAllExerciseLogs { logs, error in
                            print("All logs successfully fetched")
                        }
                                                    
                            
                        //Check if the user currently has a workout
                        if let workout = self.workoutService.getTodaysWorkout() {
                            
                            WorkoutService.sharedInstance.fetchCurrentWorkoutSummary(byWorkoutId: workout.id) { workoutSummary, error in
                                print("workoutSummary feteched")
                            }
                                                                
                            WorkoutService.sharedInstance.workout = workout
                            self.initializeLogs { result in
                                switch result {
                                case .success(let message):
                                    print(message)
                                    // Fetch all the previous summaries
                                    self.setAllConfigFlags()
                                    
                                    
                                case .failure(let error):
                                    print("failed to initialize logs: \(error)")
                                }
                            }
                        } else {
                            // Fetch favorite exercises
                            UserService.sharedInstance.fetchFavoriteExercises { (favorites, error) in
                                guard let favorites = favorites, error == nil else {
                                    print("Error fetching favorites: \(error?.localizedDescription ?? "unknown error")")
                                    return
                                }
                            }
                            
                            self.isWorkoutInProgress = false
                            self.workoutService.workout = nil
                            self.exerciselogService.logs = [ExerciseLog]()
                            self.workoutStartTime = nil
                            self.setAllConfigFlags()
                        }
                    case .failure(_):
                        print("problem getting all the exercises")
                    }
                }
            } else {
                main {
                    self.isConfigured = true
                }
            }
        } catch {
            print(error)
        }
    }
    
    func restorePurchase() {
        Task {
            do {
                _ = try await Purchases.shared.restorePurchases()
            } catch {
                print("unable to restore purchases")
            }
        }
    }
    
    func setAllConfigFlags() {
        DispatchQueue.main.async {
            self.isConfigured = true
            self.registrationComplete = true
        }
    }
    
    func saveWorkoutProgressState() {
        UserDefaults.standard.set(isWorkoutInProgress, forKey: "isWorkoutInProgress")
        if let startTime = workoutStartTime {
            let timeInterval = startTime.timeIntervalSince1970
            UserDefaults.standard.set(timeInterval, forKey: "workoutStartTime")
        }
    }
    
    func loadWorkoutProgressState() {
        DispatchQueue.main.async {
            self.isWorkoutInProgress = UserDefaults.standard.bool(forKey: "isWorkoutInProgress")
            if let timeInterval = UserDefaults.standard.object(forKey: "workoutStartTime") as? Double {
                self.workoutStartTime = Date(timeIntervalSince1970: timeInterval)
            }
        }
    }
    
    func cleanUpWorkoutInProgressWorkout() {
        self.isWorkoutInProgress = false
        self.workoutStartTime = nil
        self.isWorkoutInProgress = false

        self.saveWorkoutProgressState()
        UserService.sharedInstance.settings.suggestedWorkScore = ""
        
        //cleanup local storage
        UserDefaults.standard.removeObject(forKey: "ExerciseLogs")
        ExerciseLogService.sharedInstance.logs = [ExerciseLog]()
        
        UserDefaults.standard.removeObject(forKey: "isWorkoutInProgress")
        WorkoutService.sharedInstance.clearTodaysWorkout()
    }
    
    func requestTrackingAuthorization() {
        ATTrackingManager.requestTrackingAuthorization(completionHandler: { status in
            // handle the authorization status
            switch status {
            case .authorized:
                // Tracking authorization dialog was shown
                // and permission has been granted.
                print("Permission granted.")
                print(ASIdentifierManager.shared().advertisingIdentifier)
                
            case .denied:
                // Tracking authorization dialog was
                // shown and permission has been denied.
                print("Permission denied.")
                
            case .notDetermined:
                // Tracking authorization dialog has not been shown.
                print("Permission not determined.")
                
            case .restricted:
                // The device is not eligible for tracking.
                print("Permission restricted.")
                
            @unknown default:
                print("Unknown status.")
            }
        })
    }
    
    func initializeLogs(completion: @escaping (Result<[ExerciseLog], Error>) -> Void) {
        var logs = [ExerciseLog]()
        var user = UserService.sharedInstance.user
        
        guard let todaysWorkout = WorkoutService.sharedInstance.workout else {
            return
        }
        
        guard let user = user else {
            return
        }
        
        let workoutId = todaysWorkout.id
        ExerciseLogService.sharedInstance.fetchExerciseLogsForWorkout(workoutId, userId: user.id) { logs, error in
            if let logs {
                ExerciseLogService.sharedInstance.logs = logs
            }
        }
        
        self.crossCheckExercises()
    }
    
    func crossCheckExercises(_ updatedExercise: Exercise? = nil) {
        // If an updatedExercise was passed in, update that first
        if let updatedExercise = updatedExercise {
            if let index = ExerciseLogService.sharedInstance.logs.firstIndex(where: { $0.exercise.id == updatedExercise.id }) {
                ExerciseLogService.sharedInstance.logs[index].exercise = updatedExercise
            }
        }
        
        // Fetch favorite exercises
        UserService.sharedInstance.fetchFavoriteExercises { (favorites, error) in
            guard let favorites = favorites, error == nil else {
                print("Error fetching favorites: \(error?.localizedDescription ?? "unknown error")")
                return
            }
            
            // Do a cross check on the logs and apply any updates to the exercises in the logs
            for (index, log) in ExerciseLogService.sharedInstance.logs.enumerated() {
                // Check if the log exercise is in favorites
                if let favoriteExercise = favorites.first(where: { $0.id == log.exercise.id }) {
                    ExerciseLogService.sharedInstance.logs[index].exercise = favoriteExercise
                }
                // If not in favorites, check if the exercise exists in allExercises and is not the updatedExercise
                else if let existingExercise = WorkoutService.sharedInstance.allExercises.first(where: { $0.id == log.exercise.id }),
                        existingExercise.id != updatedExercise?.id {
                    ExerciseLogService.sharedInstance.logs[index].exercise = existingExercise
                }
            }
            
            self.cacheWorkoutVideos()
        }
    }
    
    private func cacheWorkoutVideos() {
        guard let todaysWorkout = WorkoutService.sharedInstance.workout else {
            return
        }
        
        let logs = ExerciseLogService.sharedInstance.logs
        let exercises = logs.map { $0.exercise }
        
        // Cache the first 10 videos of each exercise
        for log in logs {
            let videosToCache = log.exercise.videos.prefix(10)
            for video in videosToCache {
                guard let videoURL = URL(string: video.videoURL) else { continue }
                VideoCacheManager.shared.cacheVideo(for: videoURL, workoutId: todaysWorkout.id)
            }
        }
    }

    private func updateExerciseLogs(logs: [ExerciseLog]) {
        for log in logs {
            WorkoutService.sharedInstance.updateExerciseLog(log: log, userId: log.userId, workoutId: log.workoutId) { error in
                if let err = error {
                    print(err.localizedDescription)
                }
            }
        }
    }


    
    func generateWorkout(withPreDefinedExercises: [Exercise] = [Exercise](), bodyPartsInput: [String], withVideos: Bool, completion: @escaping (Result<Workout, Error>) -> Void) {
        guard let u = UserService.sharedInstance.user else {
            print("Unable to get the user")
            return
        }
        
        let bodyPartsArray = bodyPartsInput.flatMap { input -> [BodyPart] in
            if input.lowercased() == "back" {
                // Replace "back" with "lats", "traps", and "rhomboids"
                return ["lats", "traps", "rhomboids"].compactMap { BodyPart(rawValue: $0) }
            } else {
                // Return the original body part if it's not "back"
                return BodyPart(rawValue: input.lowercased()).map { [$0] } ?? []
            }
        }
        
        //Create a list of the possible exercises we can recommend for the user.
        let filteredExercises = WorkoutService.sharedInstance.allExercises.filter { exercise in
            let exerciseBodyPartsSet = Set(exercise.primaryBodyParts)
            let targetBodyPartsSet = Set(bodyPartsArray)
            return !exerciseBodyPartsSet.isDisjoint(with: targetBodyPartsSet)
        }
        
        //Filter only exercises with videos
        let filterWithVideos = WorkoutService.sharedInstance.filterExercisesWithVideos(exercises: WorkoutService.sharedInstance.allExercises).filter { exercise in
            let exerciseBodyPartsSet = Set(exercise.primaryBodyParts)
            let targetBodyPartsSet = Set(bodyPartsArray)
            return !exerciseBodyPartsSet.isDisjoint(with: targetBodyPartsSet)
        }
        
        let prioritizedUserIds = UserService.sharedInstance.followsISent.filter { $0.isUserContentPrioritized }.map { $0.toUser.id }

        let exerciseList: [String]

        if prioritizedUserIds.count > 0 {
            // Filter exercises from prioritized users
            let prioritizedExercises = filterWithVideos.filter { exercise in
                exercise.videos.contains { video in
                    prioritizedUserIds.contains(video.userId)
                }
            }
            
            // Determine the final list of exercises
            if withVideos {
                exerciseList = prioritizedExercises.map { $0.name }
            } else {
                exerciseList = filteredExercises.map { $0.name }
            }
            
            //We need to do a check here. if the prioritized user doesnt have more than 6 exercises to build a routine with, we need to then be able to just use exercises from others. We should be able to just use any exercise in the filterWithVideo array, as long as we already havent included it in our list. So
            if exerciseList.count < 6 {
                
            }
        } else {
            exerciseList = withVideos ?
            filterWithVideos.map { $0.name } :
            filteredExercises.map { $0.name }
        }
        
        
        
        // Predefined exercise mapping
        let predefinedExercise = withPreDefinedExercises.map { $0.name }     
        
        // Replace "back" with "lats", "traps", and "rhomboids" if it's in the input
        let modifiedBodyParts = bodyPartsInput.flatMap { bodyPart -> [String] in
            if bodyPart.lowercased() == "back" {
                return ["latissimus dorsi", "trapezius", "rhomboids"]
            } else {
                return [bodyPart]
            }
        }
        
        let bodyPartsAsString = modifiedBodyParts.joined(separator: ", ")
        let exercisesAsString = exerciseList.joined(separator: ", ")
        let allExercisesAsString = WorkoutService.sharedInstance.allExercises.map { $0.name }.joined(separator: ", ")
        let predefinedExercisesAsStrings = predefinedExercise.joined(separator: ", ")
        
        self.claudeService.generateWorkout(withPreDefinedExercises: predefinedExercisesAsStrings, bodyPartsInput: bodyPartsAsString, goal: "\(u.goal.map{$0.rawValue}.joined(separator: ",")) and \(u.additionalGoals)", exerciseList: exercisesAsString, allExercises: allExercisesAsString, isTesting: false) { results in
            switch results {
            case .success(let chosenExercises):
                guard let exercise2DimensionalArray = chosenExercises else {
                    print("problem returning the 2 dimensional array of exercise names")
                    return
                }
                                
                let flattenedArray = exercise2DimensionalArray.flatMap { $0 }
                
                self.workoutService.fetchExercises(byNames: flattenedArray) { result in
                    switch result {
                    case .success(let exercises):
                        // Map them into an [ExerciseReference], and they should be in the same position as the string names in chosenExercises
                        var index = 0
                        let exerciseRefArray: [ExerciseReference] = exercise2DimensionalArray.flatMap { exerciseNames in
                            let groupExercises = exercises.filter { exerciseNames.contains($0.name) }
                            let groupExercisesRef = groupExercises.map { ExerciseReference(exercise: $0, groupId: index) }
                            index += 1
                            return groupExercisesRef
                        }
                    
                        let exerciseDetails = exerciseRefArray.map { ExerciseDetail(exerciseName: $0.exercise.name, matchedDatabaseExercise: $0.exercise, sets: "\($0.exercise.sets)", reps: ["\($0.exercise.reps)"], weight: "0", notes: "", isSplit: false, isMissing: false, groupId: $0.groupId, closestMatch: [Exercise]()) }
                        
                        self.formatWorkoutAndInitializeLogs(exerciseDetails: exerciseDetails, workoutAuthor: "PulseAI") { results in
                            switch results {
                            case .success(let details):
                                WorkoutService.sharedInstance.updateWorkoutSession(details.0, exerciseLogs: details.1, workoutId: details.0.id)
                                ExerciseLogService.sharedInstance.logs = details.1
                                WorkoutService.sharedInstance.workout = details.0
                                
                                DispatchQueue.main.async {
                                    self.isWorkoutInProgress = false
                                    self.workoutStartTime = nil
                                    
                                    self.saveWorkoutProgressState()
                                    self.isConfigured = true
                                    self.registrationComplete = true
                                }
                                WorkoutService.sharedInstance.saveTodaysWorkout(workout: details.0)
                                                    
                                completion(.success(details.0))

                                self.crossCheckExercises()
                            case .failure(let error):
                                print(error)
                            }
                        }
                        
                    case .failure(_):
                        print("Unable to fetch exercises from list of names")
                        completion(.failure(NSError(domain: "Unable to fetch exercises from list of names", code: -1, userInfo: nil)))
                    }
                }
            case .failure(let error):
                print(error)
                completion(.failure(error))
            }
        }
    }
    
    func generateWorkoutFromSummary(workoutSummary: WorkoutSummary, completion: @escaping (Result<Workout, Error>) -> Void) {
        // Ensure we have access to the user and all exercises
        guard let user = UserService.sharedInstance.user else {
            completion(.failure(NSError(domain: "User not found", code: 401, userInfo: nil)))
            return
        }
        
        // Fetch the existing workout to reuse its structure
        WorkoutService.sharedInstance.fetchWorkout(byId: workoutSummary.workoutId) { existingWorkout, error in
            guard let existingWorkout = existingWorkout else {
                completion(.failure(error ?? NSError(domain: "Workout not found", code: 404, userInfo: nil)))
                return
            }
            
            // Prepare new exercise logs based on the completed logs from the summary, adjusting as necessary
            let newLogs = workoutSummary.exercisesCompleted.map { log -> ExerciseLog in
                // Create a new log instance, copying details and resetting submission status
                var newLog = log
                newLog.setIsSubmitted(false) // Reset submission status
                newLog.createdAt = Date() // Update creation date
                newLog.updatedAt = Date() // Update last updated date
                
                // Potentially adjust other fields here as needed
                
                return newLog
            }

            let exerciseDetails = existingWorkout.exercises.map { ExerciseDetail(exerciseName: $0.exercise.name, matchedDatabaseExercise: $0.exercise, sets: "\($0.exercise.sets)", reps: ["\($0.exercise.reps)"], weight: "0", notes:"", isSplit: false,  isMissing: false, groupId: $0.groupId, closestMatch: [Exercise]()) }
            
            self.formatWorkoutAndInitializeLogs(exerciseDetails: exerciseDetails, workoutAuthor: existingWorkout.author) { results in
                switch results {
                case .success(let details):
                    WorkoutService.sharedInstance.updateWorkoutSession(details.0, exerciseLogs: newLogs, workoutId: details.0.id)
                    ExerciseLogService.sharedInstance.logs = newLogs
                    WorkoutService.sharedInstance.workout = details.0
                    WorkoutService.sharedInstance.saveTodaysWorkout(workout: details.0)
                    
                    DispatchQueue.main.async {
                        self.isWorkoutInProgress = false
                        self.workoutStartTime = nil
                        
                        self.saveWorkoutProgressState()
                        self.isConfigured = true
                        self.registrationComplete = true
                    }

                    completion(.success(details.0))

                    self.crossCheckExercises()
                case .failure(let error):
                    print(error)
                    
                }
            }
        }
    }
    
    func generateWorkoutSaved(workout: Workout, completion: @escaping (Result<Workout, Error>) -> Void) {
        // Ensure we have access to the user and all exercises
        guard let user = UserService.sharedInstance.user else {
            completion(.failure(NSError(domain: "User not found", code: 401, userInfo: nil)))
            return
        }
        
        // Fetch the existing workout to reuse its structure
        WorkoutService.sharedInstance.fetchWorkout(byId: workout.id) { existingWorkout, error in
            guard let existingWorkout = existingWorkout else {
                completion(.failure(error ?? NSError(domain: "Workout not found", code: 404, userInfo: nil)))
                return
            }
            
            let exerciseDetails = existingWorkout.exercises.map { ExerciseDetail(exerciseName: $0.exercise.name, matchedDatabaseExercise: $0.exercise, sets: "\($0.exercise.sets)", reps: ["\($0.exercise.reps)"], weight: "0", notes: "", isSplit: false, isMissing: false, groupId: $0.groupId, closestMatch: [Exercise]()) }
            
            self.formatWorkoutAndInitializeLogs(exerciseDetails: exerciseDetails, workoutAuthor: workout.author) { results in
                switch results {
                case .success(let details):
                    WorkoutService.sharedInstance.updateWorkoutSession(details.0, exerciseLogs: details.1, workoutId: details.0.id)
                    ExerciseLogService.sharedInstance.logs = details.1
                    WorkoutService.sharedInstance.workout = details.0
                    WorkoutService.sharedInstance.saveTodaysWorkout(workout: details.0)
                    
                    DispatchQueue.main.async {
                        self.isWorkoutInProgress = false
                        self.workoutStartTime = nil
                        
                        self.saveWorkoutProgressState()
                        self.isConfigured = true
                        self.registrationComplete = true
                    }
                    
                    completion(.success(details.0))
                    
                    self.crossCheckExercises()
                case .failure(let error):
                    print(error)
                }
            }
        }
    }
    
    func setCurrentWorkout(isWorkoutInProgress: Bool = false, startDate: Date? = nil,  workout: Workout, logs: [ExerciseLog], workoutSummary: WorkoutSummary?, completion: @escaping ()->()) {
        //Make sure the in progress state and start time is set
        self.isWorkoutInProgress = isWorkoutInProgress
        self.workoutStartTime = startDate
        self.saveWorkoutProgressState()
        let currentDate = Date()

        if let summary = workoutSummary {
            WorkoutService.sharedInstance.currentWorkoutSummary = summary
        }

        WorkoutService.sharedInstance.saveTodaysWorkout(workout: workout)
        
        guard let user = UserService.sharedInstance.user else  { return }
        
        for log in logs {
            ExerciseLogService.sharedInstance.updateExerciseLog(log: log, workout: workout)
        }
        
        var newLogs = logs
        if workout.exercises.count != logs.count {
            for exercise in workout.exercises {
                if !logs.contains(where: {$0.exercise.name == exercise.exercise.name}) {
                    var repsAndWeight = Array(repeating: RepsAndWeightLog(), count: exercise.exercise.sets)
                    
                    let newLog = ExerciseLog(id: UUID().uuidString,
                                             workoutId: workout.id,
                                             userId: user.id,
                                             exercise: exercise.exercise,
                                             logs: repsAndWeight,
                                             feedback: "",
                                             note: "",
                                             createdAt: currentDate,
                                             updatedAt: currentDate)
                    
                    newLogs.append(newLog)
                }
            }
        }
        
        // Save the workout and logs
        WorkoutService.sharedInstance.workout = workout
        ExerciseLogService.sharedInstance.logs = newLogs
        
        completion()
    }
    
    func setNewCurrentWorkout(isWorkoutInProgress: Bool = false, startDate: Date? = nil,  workout: Workout, logs: [ExerciseLog], completion: @escaping ()->()) {
        //Make sure the in progress state and start time is set
        self.isWorkoutInProgress = isWorkoutInProgress
        self.workoutStartTime = startDate
        self.saveWorkoutProgressState()
        var currentDate = Date()
        
        var newWorkout = workout
        newWorkout.createdAt = currentDate
        newWorkout.updatedAt = currentDate
        
        var newLogs = [ExerciseLog]()
        
        for log in logs {
            let newLog = log
            newLog.id = UUID().uuidString
            newLog.workoutId = newWorkout.id
            newLog.setIsSubmitted(false)
            newLog.createdAt = currentDate
            newLog.updatedAt = currentDate
            newLogs.append(newLog)
        }
        
        // Save the workout and logs
        WorkoutService.sharedInstance.workout = newWorkout
        ExerciseLogService.sharedInstance.logs = newLogs
                
        WorkoutService.sharedInstance.saveTodaysWorkout(workout: newWorkout)
        
        for log in newLogs {
            ExerciseLogService.sharedInstance.updateExerciseLog(log: log, workout: newWorkout)
        }
        
        completion()
    }
 
    func formatWorkoutAndInitializeLogs(exerciseDetails: [ExerciseDetail], workoutAuthor: String?, completion: @escaping (Result<(Workout, [ExerciseLog]), Error>) -> Void) {
        var exerciseReferences = [ExerciseReference]()
        var exerciseLogs = [ExerciseLog]()
        var workId = UUID().uuidString
                
        for detail in exerciseDetails {
            // Create an ExerciseReference with groupId set to 0
            if let dbEx = detail.matchedDatabaseExercise {
                let exerciseRef = ExerciseReference(exercise: dbEx, groupId: detail.groupId)
                exerciseReferences.append(exerciseRef)
                
                // Initialize logs based on sets and reps
                let sets = Int(detail.sets) ?? 3
                let reps = detail.reps.last ?? "12"
                let weight = Double(detail.weight) ?? 0.0
                let setsLogs = Array(repeating: RepsAndWeightLog(reps: Int(reps) ?? 12, weight: weight), count: sets)
                let log = ExerciseLog(
                    id: UUID().uuidString,
                    workoutId: workId, // Assuming a new workout ID
                    userId: UserService.sharedInstance.user?.id ?? "", // Adjust as necessary
                    exercise: Exercise(id: dbEx.id, name: dbEx.name, category: dbEx.category, primaryBodyParts: dbEx.primaryBodyParts, secondaryBodyParts: dbEx.secondaryBodyParts, tags: dbEx.tags, description: dbEx.description, steps: dbEx.steps, videos: dbEx.videos, currentVideoPosition: dbEx.currentVideoPosition, reps: reps, sets: sets, weight: weight, author: dbEx.author, createdAt: dbEx.createdAt, updatedAt: dbEx.updatedAt),
                    logs: setsLogs,
                    feedback: "",
                    note: detail.notes,
                    isSplit: detail.isSplit,
                    createdAt: Date(),
                    updatedAt: Date()
                )
                exerciseLogs.append(log)
            }
        }
        
        // Create the Workout object with ExerciseReference array
        let newWorkout = Workout(
            id: workId,
            exercises: exerciseReferences,
            logs: exerciseLogs,
            duration: 60, // Adjust duration as needed
            workoutRating: .none,
            isCompleted: false,
            author: workoutAuthor != nil ? workoutAuthor ?? "PulseAI" : UserService.sharedInstance.user?.username ?? "PulseAI",
            createdAt: Date(),
            updatedAt: Date()
        )
        
        completion(.success((newWorkout, exerciseLogs)))
    }
    
    func automateWorkoutAddition(bodyPart: [BodyPart], completion: @escaping (Result<String, Error>) -> Void) {
        //get all the exercises
        self.workoutService.getExercises { result in
            switch result {
            case .success(let exercises):
                
                WorkoutService.sharedInstance.allExercises = exercises
                
                let filteredExercises = exercises.filter { exercise in
                    let exerciseBodyPartsSet = Set(exercise.primaryBodyParts)
                    let targetBodyPartsSet = Set(bodyPart)
                    return !exerciseBodyPartsSet.intersection(targetBodyPartsSet).isEmpty
                }
                
                let exerciseNames = filteredExercises.map { $0.name }.joined(separator: ", ")
                
                self.gptService.generateThreeExercises(exerciseNames, bodyPartsInput: bodyPart.map { $0.rawValue }.joined(separator: ", ")) { result in
                    switch result {
                    case .success(let fullExercises):
                        fullExercises.forEach { ex in
                            WorkoutService.sharedInstance.saveExerciseToDatabase(exercise: ex) { status in
                                print(status)
                            }
                        }
                        
                        completion(.success(fullExercises.map { $0.name }.joined(separator: ", ")))
                        
                    case .failure(let error):
                        print(error)
                        completion(.failure(error))
                    }
                }
            case .failure(_):
                print("error getting exercises")
            }
        }
    }
    
    func loadMockData() {
        //self.userService.$savedWorkouts =
        self.userService.user = User(id: UUID().uuidString, displayName: "", email: "tee.hugh@gmail.com", username: "FitTransform01", bio: "", additionalGoals: "To slim down in my stomach area while gaining muscle in my arms", level: .novice, goal: [.gainWeight], bodyWeight: [BodyWeight](), profileImage: nil, registrationComplete: true, subscriptionType: .unsubscribed, createdAt: Date(), updatedAt: Date())
        
        self.userService.bodyWeights = Fixtures.shared.bodyWeightArrayFixture
        //  self.userService.$favorites = Fixtures.shared.favoriteExercisesArrayFixture
        
        self.workoutService.workoutSummaries = WorkoutSummaryFixtures.shared.WorkoutSummaryArrayFixture3
        self.workoutService.workout = Fixtures.shared.workoutFixture
        
        self.exerciselogService.logs = [
            ExerciseLogFixtures.shared.ExerciseLogFixtureBicepCurls,
            ExerciseLogFixtures.shared.ExerciseLogFixtureTricepDips,
            ExerciseLogFixtures.shared.ExerciseLogFixtureChinUps,
            ExerciseLogFixtures.shared.ExerciseLogFixtureHammerCurls,
            ExerciseLogFixtures.shared.ExerciseLogFixtureSideCurls
        ]
        self.exerciselogService.isTesting = true
        self.userService.isBetaUser = true
        
        self.setAllConfigFlags()
        
        self.clearVideos()
        
    }
    
    func updateQueuedWorkout(workout: Workout, logs: [ExerciseLog]) {

        
        // Update the workout in the WorkoutService
        WorkoutService.sharedInstance.updateWorkout(updatedWorkout: workout)
        WorkoutService.sharedInstance.saveTodaysWorkout(workout: workout)
        WorkoutService.sharedInstance.workout = workout
        
        WorkoutService.sharedInstance.updateWorkoutSession(workout, exerciseLogs: logs, workoutId: workout.id)
        ExerciseLogService.sharedInstance.logs = logs
    }
    
    func clearVideos() {
        WorkoutService.sharedInstance.getExercises { results in
            switch results {
            case .success(let exercises):
                let exercisesToUpdate = exercises.filter { !$0.videos.isEmpty }
                var updatedCount = 0
                for ex in exercisesToUpdate {
                    var updatedExercise = ex
                    updatedExercise.videos = []
                    
                    WorkoutService.sharedInstance.updateExercise(exercise: updatedExercise) { exercise, error in
                        if let error = error {
                            print("Failed to update exercise: \(error)")
                        } else {
                            updatedCount += 1
                            if updatedCount == exercisesToUpdate.count {
                                print("Updated all exercises")
                                // Perform any additional tasks you want here after all exercises are updated
                            }
                        }
                    }
                }
            case .failure(let error):
                print("Failed to get exercises: \(error)")
            }
        }
    }
    
    func getAppVersion() -> String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            return "\(version)"
        }
        return "Version not available"
    }
}
