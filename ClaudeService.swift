import Foundation
import UIKit
import SwiftAnthropic

class ClaudeService {
    static let sharedInstance = ClaudeService()
    
    private let service: AnthropicService
    
    private init() {
        let apiKey = ConfigManager.shared.getAnthropicAPIKey()
        self.service = AnthropicServiceFactory.service(apiKey: apiKey)
    }
    
    func sendMessage(_ message: String, completion: @escaping (Result<String, Error>) -> Void) {
        let maxTokens = 1024
        let messageParameter = MessageParameter.Message(role: .user, content: .text(message))
        let parameters = MessageParameter(model: .claude35Sonnet, messages: [messageParameter], maxTokens: maxTokens)
        
        Task {
            do {
                let response = try await service.createMessage(parameters)
                let responseText = response.content.compactMap { content -> String? in
                    switch content {
                    case .text(let text):
                        return text
                    default:
                        return nil
                    }
                }.joined()
                completion(.success(responseText))
            } catch {
                completion(.failure(error))
            }
        }
    }
    
    func sendStreamMessage(_ message: String, onReceive: @escaping (String) -> Void, onCompletion: @escaping (Result<Void, Error>) -> Void) {
        let maxTokens = 1024
        let messageParameter = MessageParameter.Message(role: .user, content: .text(message))
        let parameters = MessageParameter(model: .claude21, messages: [messageParameter], maxTokens: maxTokens, stream: true)
        
        Task {
            do {
                for try await response in try await service.streamMessage(parameters) {
                    switch response.type {
                    case "content_block_start", "content_block_delta":
                        if let text = response.contentBlock?.text {
                            onReceive(text)
                        }
                    case "message_delta":
                        if let text = response.delta?.text {
                            onReceive(text)
                        }
                    case "message_stop":
                        onCompletion(.success(()))
                    default:
                        break
                    }
                }
            } catch {
                onCompletion(.failure(error))
            }
        }
    }
    
    func sendImageAndMessage(base64Image: String, prompt: String, completion: @escaping (Result<String, Error>) -> Void) {
        let maxTokens = 1024
        
        let imageSource: MessageParameter.Message.Content.ContentObject = .image(.init(type: .base64, mediaType: .jpeg, data: base64Image))
        let text: MessageParameter.Message.Content.ContentObject = .text(prompt)
        let content: MessageParameter.Message.Content = .list([imageSource, text])
        
        let messagesParameter = [MessageParameter.Message(role: .user, content: content)]
        let parameters = MessageParameter(model: .claude3Sonnet, messages: messagesParameter, maxTokens: maxTokens)
        
        Task {
            do {
                let response = try await service.createMessage(parameters)
                let responseText = response.content.compactMap { content -> String? in
                    switch content {
                    case .text(let text):
                        return text
                    default:
                        return nil
                    }
                }.joined()
                completion(.success(responseText))
            } catch {
                completion(.failure(error))
            }
        }
    }
    
    func scanFood(image: UIImage, caption: String, completion: @escaping (Result<Meal, Error>) -> ()) {
        // Assuming `image` is already compressed and converted to a base64-encoded string
        guard let base64Image = image.toBase64() else {
            // Handle error: unable to convert image to base64
            return
        }

        // Request a specific format for macronutrients in the prompt
        let prompt = """
        Identify, and analyze the following image of food and provide an estimation of its macronutrients in the following format:
        name: name of the meal(Choose a name that best describes the food that is in the image).
        calories: value
        protein: value(number is in grams however ONLY SHOW NUMERIC VALUE)
        carbs: value(number is in grams however ONLY SHOW NUMERIC VALUE)
        fat: value(number is in grams however ONLY SHOW NUMERIC VALUE)
        """
        
        sendImageAndMessage(base64Image: base64Image, prompt: prompt) { results in
            switch results {
            case .success(let nutritionInfo):
                // Handle the successful response
                let meal = self.parseNutritionInfo(nutritionInfo: nutritionInfo, caption: caption)
                completion(.success(meal))
            case .failure(let error):
                // Handle the error
                completion(.failure(error))
                print(error.localizedDescription)
            }
        }
    }
    
    func estimateCaloriesBurned(workoutSummary: WorkoutSummary, completion: @escaping (Result<String, Error>) -> Void) {
        
        var intervalDuration = workoutSummary.completedAt?.timeIntervalSince(workoutSummary.createdAt)
        var stringDuration: String

        if let duration = intervalDuration {
            let twoHoursInSeconds = TimeInterval(2 * 60 * 60) // 2 hours in seconds as TimeInterval
            
            if duration > twoHoursInSeconds {
                stringDuration = "2 hours"
            } else {
                stringDuration = workoutSummary.calculateDuration()
            }
        } else {
            stringDuration = workoutSummary.calculateDuration()
        }
        
        let prompt = """
                    Estimate the total calories burned during a workout given the following details:

                    - Duration: \(stringDuration)
                    - Exercises and reps/sets completed: \(parseWorkoutData(workoutSummary.exercisesCompleted))
        
        Respond with only the numeric value of the total calories burned, without any additional explanations or text.
               
        """
        
        let temperature: Double = 0.3
        let maxTokens = 50

        sendMessage(prompt) { results in
            switch results {
            case .success(let caloriesInfo):
                completion(.success(caloriesInfo))
            case .failure(let error):
                // Handle the error
                completion(.failure(error))
                print(error.localizedDescription)
            }
        }
    }
    
    func parseWorkoutData(_ exercises: [ExerciseLog]) -> [String: Any] {
        var parsedExercises: [[String: Any]] = []
        
        for exercise in exercises {
            var exerciseData: [String: Any] = [
                "name": exercise.exercise.name,
                "sets": exercise.logs.count,
                "reps": exercise.logs.first?.reps ?? 0,
                "weight": exercise.logs.first?.weight ?? 0.0
            ]
            
            // Check if the exercise is split (e.g., left and right reps/weights)
            if let isSplit = exercise.isSplit, isSplit {
                exerciseData["leftReps"] = exercise.logs.first?.leftReps ?? 0
                exerciseData["leftWeight"] = exercise.logs.first?.leftWeight ?? 0.0
            }
            
            // Check if the exercise is bodyweight
            if let isBodyWeight = exercise.isBodyWeight, isBodyWeight {
                exerciseData["isBodyWeight"] = true
            }
            
            parsedExercises.append(exerciseData)
        }
        
        let parsedData: [String: Any] = [
            "exercises": parsedExercises
        ]
        
        return parsedData
    }
    
    func recommendMacros(goals: String, completion: @escaping (Result<(calories: Int, protein: Int, carbs: Int, fat: Int), Error>) -> Void) {
        let prompt = """
                    Can you recommend macros that I should eat for the day based on my goals:'\(goals)'

                    Provide me with the macronutrients in the following format:
                    name: Macronutrients.
                    calories: value
                    protein: value(number is in grams however ONLY SHOW NUMERIC VALUE)
                    carbs: value(number is in grams however ONLY SHOW NUMERIC VALUE)
                    fat: value(number is in grams however ONLY SHOW NUMERIC VALUE)
        """
        
        let temperature: Double = 0.5
        let maxTokens = 200
        
        sendMessage(prompt) { results in
            switch results {
            case .success(let nutritionInfo):
                // Handle the successful response
                let meal = self.parseNutritionInfo(nutritionInfo: nutritionInfo, caption: "")
                print(meal)
                completion(.success((calories: meal.calories, protein: meal.protein, carbs: meal.carbs, fat: meal.fat)))
            case .failure(let error):
                // Handle the error
                completion(.failure(error))
                print(error.localizedDescription)
            }
        }
    }
    
    func analyzeMeal(title: String, description: String, caption: String, completion: @escaping (Result<Meal, Error>) -> Void) {
        let prompt = """
                    Analyze the following description of a meal:'\(title)-'
                    '\(description)'

                    food and provide an estimation of its macronutrients in the following format:
                    name: name of the meal(Choose a name that best describes the food that is in the image).
                    calories: value
                    protein: value(number is in grams however ONLY SHOW NUMERIC VALUE)
                    carbs: value(number is in grams however ONLY SHOW NUMERIC VALUE)
                    fat: value(number is in grams however ONLY SHOW NUMERIC VALUE)
                    category: value(choose one or more categories from the list provided)

                    Here's the list of categories:
                    - grains
                    - fruits
                    - vegetables
                    - dairy
                    - meat
                    - fishAndSeafood
                    - eggs
                    - nutsSeedsAndLegumes
                    - fatsAndOils
                    - sweetsAndDesserts
                    - snacks
                    - water
                    - juices
                    - softDrinks
                    - alcoholicDrinks
                    - coffeeAndTea
                    - fastFood
                    - condimentsAndSauces
                    - soupsAndBroths
                    - processedAndPrepackagedFoods
                    - ethnicOrRegionalCuisines
                    - breakfastFoods
        """


        let temperature: Double = 0.5
        let maxTokens = 300
        
        sendMessage(prompt) { results in
            switch results {
            case .success(let nutritionInfo):
                // Handle the successful response
                let meal = self.parseNutritionInfo(nutritionInfo: nutritionInfo, caption: caption)
                completion(.success(meal))
            case .failure(let error):
                // Handle the error
                completion(.failure(error))
                print(error.localizedDescription)
            }
        }
    }
    
    func parseNutritionInfo(nutritionInfo: String, caption: String) -> Meal {
        var response = nutritionInfo.replacingOccurrences(of: "*", with: "")
        let lines = response.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        
        var mealName: String = ""
        var categories: [FoodIcons] = []
        var calories: Int = 0
        var protein: Int = 0
        var fat: Int = 0
        var carbs: Int = 0
        
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            
            if parts.count == 2 {
                let key = parts[0]
                let value = parts[1]
                
                switch key.lowercased() {
                case "name":
                    mealName = value
                case "calories":
                    calories = Int(value) ?? 0
                case "protein":
                    protein = Int(value) ?? 0
                case "carbs":
                    carbs = Int(value) ?? 0
                case "fat":
                    fat = Int(value) ?? 0
                case "category":
                    let categoryStrings = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    categories = categoryStrings.compactMap { FoodIcons(rawValue: String($0)) }
                default:
                    break
                }
            }
        }
        
        func calculateCalories(carbs: Int, fat: Int, protein: Int) -> Int {
            let caloriesFromCarbs = carbs * 4
            let caloriesFromFat = fat * 9
            let caloriesFromProtein = protein * 4
            
            return caloriesFromCarbs + caloriesFromFat + caloriesFromProtein
        }
        
         return Meal(id: UUID().uuidString,
                    name: mealName,
                    categories: categories,
                    caption: caption,
                    calories: calculateCalories(carbs: carbs, fat: fat, protein: protein),
                    protein: protein,
                    fat: fat,
                    carbs: carbs,
                    image: "",
                    createdAt: Date(),
                    updatedAt: Date())
    }
    
    func generateWorkout(withPreDefinedExercises: String = "", bodyPartsInput: String, goal: String, exerciseList: String, allExercises: String, isTesting: Bool, completion: @escaping (Result<[[String]]?, Error>) -> Void) {

        let promptTemplate = RemoteConfigService.sharedInstance.getWorkoutPrompt()
        let prompt = promptTemplate
            .replacingOccurrences(of: "{{bodyParts}}", with: bodyPartsInput)
            .replacingOccurrences(of: "{{goal}}", with: goal)
            .replacingOccurrences(of: "{{exerciseList}}", with: exerciseList)
            .replacingOccurrences(of: "{{withPreDefinedExercises}}", with: withPreDefinedExercises)
            .replacingOccurrences(of: "{{allExercises}}", with: allExercises)

        let temperature: Double = 0.5
        let maxTokens = 200

        print(prompt)
        
        sendMessage(prompt) { results in
            switch results {
            case .success(let response):
                print("These exercises were chosen by GPT: \(response)")

                let parsedExercises = self.parseExercises(input: response)
                completion(.success(parsedExercises))
            case .failure(let error):
                print(error)
                completion(.failure(error))
            }
        }
    }
    
    func parseExercises(input: String) -> [[String]] {
        // Removing the leading and trailing brackets
        let trimmedInput = input.dropFirst().dropLast()

        // Splitting the string into components by "], ["
        let components = trimmedInput.components(separatedBy: "], [")

        // For each component, further split it into individual exercise names
        let exercises = components.map { component in
            return component.components(separatedBy: ", ")
        }

        return exercises
    }
    
    
}
