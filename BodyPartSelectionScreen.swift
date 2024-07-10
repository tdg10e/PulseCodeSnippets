//
//  BodyPartSelectionScreenView.swift
//  QuickLifts
//
//  Created by Tremaine Grant on 7/11/23.
//

import SwiftUI

class BodyPartSelectionViewModel: ObservableObject {
    @Published var appCoordinator: AppCoordinator
    @Published var bodyPartsViewModel: MultipleChoiceCardViewModel
    @Published var advancedBodyPartsViewModel: MultipleChoiceCardViewModel
    @Published var selectedBodyParts: [String] = [String]()
    
    @Published var isModal: Bool = false
    
    @Published var isLoading: Bool = false
    @Published var loadingIcon: Icon?
    
    var onGenerateWorkout: (Result<Workout, any Error>, [BodyPart]) -> ()
    var onInitiateGenerate: ()->()
    
    init(appCoordinator: AppCoordinator, bodyPartsViewModel: MultipleChoiceCardViewModel, advancedBodyPartsViewModel: MultipleChoiceCardViewModel, selectedBodyParts: [String], isModal: Bool = false, onInitiateGenerate: @escaping () -> (), onGenerateWorkout: @escaping (Result<Workout, any Error>, [BodyPart]) -> ()) {
        self.appCoordinator = appCoordinator
        self.bodyPartsViewModel = bodyPartsViewModel
        self.advancedBodyPartsViewModel = advancedBodyPartsViewModel
        self.selectedBodyParts = selectedBodyParts
        self.isModal = isModal
        self.onInitiateGenerate = onInitiateGenerate
        self.onGenerateWorkout = onGenerateWorkout
        
    }
    
    func removeRecommendation(_ recommendation: String) {
        selectedBodyParts.removeAll(where: { $0 == recommendation })
    }
    
    func generate(withVideos: Bool, completion: @escaping () -> ()) {
        self.isLoading = true

        // Create a dispatch work item for the timeout
        let timeoutWorkItem = DispatchWorkItem {
            self.isLoading = false
            self.appCoordinator.showToast(viewModel: ToastViewModel(message: "Timeout: Failed to generate workout. Please try again.", backgroundColor: .white, textColor: .secondaryCharcoal, onClose: {
                self.appCoordinator.hideToast()
            }))
        }

        // Schedule the timeout work item to execute after 45 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: timeoutWorkItem)
        
        self.appCoordinator.serviceManager.generateWorkout(bodyPartsInput: self.selectedBodyParts, withVideos: withVideos) { workout in
            // Cancel the timeout work item if the workout is generated successfully
            timeoutWorkItem.cancel()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.isLoading = false
                self.onGenerateWorkout(workout, self.selectedBodyParts.map { BodyPart(rawValue: $0) ?? .abs })
                completion()
            }
        }
    }
        
    func generateWorkout(withVideos: Bool, completion: @escaping () -> ()) {
        if WorkoutService.sharedInstance.allExercises.count > 5 {
            self.onInitiateGenerate()
            generate(withVideos: withVideos, completion: {
                completion()
            })
        } else {
            WorkoutService.sharedInstance.getExercises { result in
                switch result {
                case .success(_):
                    self.onInitiateGenerate()
                    self.generate(withVideos: withVideos, completion: {
                        completion()
                    })
                case .failure(_):
                    self.appCoordinator.closeModals()
                    self.appCoordinator.showToast(viewModel: ToastViewModel(message: "An error occurred generating the workout. Try it again in a few seconds.", backgroundColor: .white, textColor: .secondaryCharcoal, onClose: {
                        self.appCoordinator.hideToast()
                    }))
                }
            }
        }
    }
}

struct BodyPartSelectionView: View {
    @ObservedObject var viewModel: BodyPartSelectionViewModel
    @State var recommendedBodyParts: [String] = []
    @State var isLoadingRecommnedations: Bool = false
    @State var showAdvancedBodyParts = false
    
    private var gridSpacing: CGFloat {
        recommendedBodyParts.contains(where: { $0.count > 5 }) ? 120 : 50
    }

    private var grid: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: 4)
    }
    
    func recommendBodyPartsForWorkouts() {
        self.isLoadingRecommnedations = true
        
        if let lastWorkoutDate = viewModel.getLastWorkoutDate() {
            let daysSinceLastWorkout = Calendar.current.dateComponents([.day], from: lastWorkoutDate, to: Date()).day ?? 0
            
            if daysSinceLastWorkout < 7 {  // Assuming a week is "recent"
                let recentlyWorkedOutParts = viewModel.getRecentlyWorkedOutBodyParts()
                
                let bodyPartsAvailable = viewModel.bodyPartsViewModel.options
                    .filter { option in
                        if let bodyPart = BodyPart(rawValue: option.title.lowercased()) {
                            return !recentlyWorkedOutParts.contains(bodyPart)
                        }
                        return true
                    }
                    .map { $0 }
                
                GPTService.sharedInstance.recommendBodyParts(bodyParts: bodyPartsAvailable.map{$0.title}) { results in
                    switch results {
                    case .success(let parts):
                        delay(10) {
                            self.isLoadingRecommnedations = false
                            recommendedBodyParts = parts.map { $0.rawValue.capitalized }
                            self.selectRecommendations()
                        }
                    case .failure(let error):
                        print(error.localizedDescription)
                        self.isLoadingRecommnedations = false
                    }
                }
            } else {
                delay(5) {
                    let strongestBodyParts = viewModel.getStrongestBodyParts()
                    recommendedBodyParts = strongestBodyParts.shuffled().prefix(2).map { $0.rawValue.capitalized }
                    self.selectRecommendations()
                    self.isLoadingRecommnedations = false
                }
            }
            
        } else if viewModel.isNewUser() {
            delay(5) {
                let recommendedForNewUsers = viewModel.getRecommendedBodyPartsForNewUsers()
                recommendedBodyParts = recommendedForNewUsers.shuffled().prefix(2).map { $0.rawValue.capitalized }
                self.selectRecommendations()
                self.isLoadingRecommnedations = false
            }
        } else {
            GPTService.sharedInstance.recommendBodyParts(bodyParts: viewModel.bodyPartsViewModel.options.map{$0.title}) { results in
                switch results {
                case .success(let parts):
                    delay(10) {
                        self.isLoadingRecommnedations = false
                        recommendedBodyParts = parts.map { $0.rawValue.capitalized }
                        self.selectRecommendations()
                    }
                case .failure(let error):
                    print(error.localizedDescription)
                }
            }
        }
    }
    
    func selectRecommendations() {
        viewModel.bodyPartsViewModel.selectedOptions = recommendedBodyParts
        viewModel.selectedBodyParts = recommendedBodyParts
    }
    
    var body: some View {
        ZStack {
            Color.secondaryCharcoal
            ScrollView {
                if viewModel.isModal {
                    Spacer()
                        .frame(height: 16)
                }
                HStack {
                    Text(viewModel.bodyPartsViewModel.question)
                        .font(.largeTitle)
                        .bold()
                        .foregroundColor(.secondaryWhite)
                        .padding(.top, 100)
                        .padding(.bottom, 16)
                        .padding(.horizontal)
                    Spacer()
                }

                HStack {
                    Text(viewModel.bodyPartsViewModel.subQuestion)
                        .foregroundColor(.secondaryWhite)
                        .padding(.horizontal, 20)
                    Spacer()
                }
                .padding(.bottom)
                
                MultipleChoiceCardView(viewModel: viewModel.bodyPartsViewModel, onSubmittedAnswer: { selectedOptions in
                    print("Body parts selected: \(selectedOptions)")
                    viewModel.selectedBodyParts = selectedOptions
                    
                    // Check the count of selected options
                    if viewModel.selectedBodyParts.count > 3 {
                        // Show the notification modal if more than 3 body parts have been selected
                        viewModel.appCoordinator.showNotificationModal(viewModel: CustomModalViewModel(type: .confirmation, title: "Too Many Body Parts Selected", message: "Selecting more than 3 body parts for one session is not advised. Are you sure you want to continue?", primaryButtonTitle: "Yes", secondaryButtonTitle: "Cancel",
                            primaryAction: { message in
                                viewModel.appCoordinator.hideNotification()
                            },
                            secondaryAction: {
                            
                            viewModel.selectedBodyParts.removeLast()
                            viewModel.bodyPartsViewModel.selectedOptions.removeLast()
                            
                            
                            viewModel.appCoordinator.hideNotification()
                        }))
                    }
                })
                .padding(.bottom, 12)
                
                if showAdvancedBodyParts {
                    HStack {
                        Seperator(color: .secondaryWhite, height: 2)
                            .padding(.leading)
                        Text("Advanced")
                            .font(.subheadline)
                            .foregroundColor(.secondaryWhite)
                            .padding(.horizontal)
                        Seperator(color: .secondaryWhite, height: 2)
                            .padding(.trailing)
                    }
                    .padding(.bottom, 12)

                    //advanced body parts
                    MultipleChoiceCardView(viewModel: viewModel.advancedBodyPartsViewModel, onSubmittedAnswer: { selectedOptions in
                        print("Body parts selected: \(selectedOptions)")
                        viewModel.selectedBodyParts = selectedOptions
                        
                        // Check the count of selected options
                        if viewModel.selectedBodyParts.count > 3 {
                            // Show the notification modal if more than 3 body parts have been selected
                            viewModel.appCoordinator.showNotificationModal(viewModel: CustomModalViewModel(type: .confirmation, title: "Too Many Body Parts Selected", message: "Selecting more than 3 body parts for one session is not advised. Are you sure you want to continue?", primaryButtonTitle: "Yes", secondaryButtonTitle: "Cancel",
                                primaryAction: { message in
                                    viewModel.appCoordinator.hideNotification()
                                },
                                secondaryAction: {
                                
                                viewModel.selectedBodyParts.removeLast()
                                viewModel.bodyPartsViewModel.selectedOptions.removeLast()
                                
                                
                                viewModel.appCoordinator.hideNotification()
                            }))
                        }
                    })
                    .padding(.bottom, 12)
                    
                    Button {
                        showAdvancedBodyParts.toggle()
                    } label: {
                        Text("Hide Advanced Body Parts")
                            .foregroundStyle(Color.white)
                            .font(.subheadline)
                    }
                    .padding(.bottom, 200)
                    
                } else {
                    Button {
                        showAdvancedBodyParts.toggle()
                    } label: {
                        Text("Show Advanced Body Parts")
                            .foregroundStyle(Color.white)
                            .font(.subheadline)
                    }
                    .padding(.bottom, 200)

                }
            }
            VStack {
                Spacer()
                VStack {
                    VStack {
                        if isLoadingRecommnedations {
                            HStack {
                                Spacer()
                                AILoadingBadgeView(actionText: "thinking")
                            }
                            .padding(.horizontal)
                        }
                        
                        LazyVGrid(columns: grid, alignment: .leading, spacing: 0) {
                            ForEach(recommendedBodyParts, id: \.self) { bodyPart in
                                ChipTileView(viewModel: ChipTileViewModel(text: bodyPart, mode: .bodyParts), onClosePressed: {
                                    viewModel.removeRecommendation(bodyPart)
                                    recommendedBodyParts.removeAll(where: {$0 == bodyPart})
                                    viewModel.bodyPartsViewModel.removeSelectedOption(bodyPart)
                                })
                                .flexibleView()
                            }
                        }
                        .padding(.horizontal, 20)
                        
                    }
                    .padding(.top, 24)
                                        
                    if viewModel.selectedBodyParts.isEmpty {
                        ConfirmationButton(title: "Recommend", type: viewModel.isLoading ? .loading : .primaryLargeBorderedConfirmation, isLoading: viewModel.isLoading, action:  {
                            self.recommendBodyPartsForWorkouts()
                            FirebaseService.sharedInstance.logAnalyticsEvent(type: .recommendedBodyPart, parameters: ["email": UserService.sharedInstance.user?.email ?? "unavailable"])
                        })
                        .padding(.horizontal, 20)
                        .padding(.bottom, 36)
                        
                    } else {
                        ConfirmationButton(title: "Generate workout", type: .primaryLargeConfirmation) {
                            viewModel.appCoordinator.showLoadingScreen(type: .loadingTransparent(message: ""))
                            viewModel.generateWorkout(withVideos: true, completion: {
                                viewModel.appCoordinator.hideLoaderScreen()
                            })
                        }
                        .padding(.bottom, 60)
                        .padding(.horizontal, 20)
                    }
                }
                .background(Color.secondaryCharcoal)
            }
        }
        .edgesIgnoringSafeArea(.all)
    }
}

extension BodyPartSelectionViewModel {
    // 1. Fetch the last workout date for the user
    func getLastWorkoutDate() -> Date? {
        guard let summaries = WorkoutService.sharedInstance.workoutSummaries else {
            return nil
        }

        // Sort the summaries based on the createdAt property in descending order
        // and then retrieve the most recent date.
        let sortedSummaries = summaries.sorted {
            $0.createdAt > $1.createdAt
        }
        
        return sortedSummaries.first?.createdAt
    }

    
    func getRecentlyWorkedOutBodyParts(fromRecentWorkouts n: Int = 2) -> [BodyPart] {
        guard let summaries = WorkoutService.sharedInstance.workoutSummaries else {
            return []
        }

        // Sort summaries by `createdAt` in descending order to get the most recent first
        let sortedSummaries = summaries.sorted {
            $0.createdAt > $1.createdAt
        }

        // Get the body parts from the top n summaries
        var recentBodyParts: [BodyPart] = []
        for summary in sortedSummaries.prefix(n) {
            recentBodyParts.append(contentsOf: summary.bodyParts)
        }

        // Return unique body parts
        return Array(Set(recentBodyParts))
    }

    
    func getStrongestBodyParts(top n: Int = 3) -> [BodyPart] {
        guard let summaries = WorkoutService.sharedInstance.workoutSummaries else {
            return []
        }

        // Create a dictionary to count the frequency of each body part
        var bodyPartCounts: [BodyPart: Int] = [:]
        
        for summary in summaries {
            for bodyPart in summary.bodyParts {
                bodyPartCounts[bodyPart, default: 0] += 1
            }
            for secondaryBodyPart in summary.secondaryBodyParts {
                bodyPartCounts[secondaryBodyPart, default: 0] += 1
            }
        }

        // Sort the body parts based on their frequency
        let sortedBodyParts = bodyPartCounts.sorted {
            $0.value > $1.value
        }.map {
            $0.key
        }
        
        // Return the top n body parts
        return Array(sortedBodyParts.prefix(n))
    }

    func isNewUser() -> Bool {
        guard let summaries = WorkoutService.sharedInstance.workoutSummaries else {
            return true // Assume new user if summaries is nil
        }
        return summaries.isEmpty
    }

    func getRecommendedBodyPartsForNewUsers() -> [BodyPart] {
        let recommendedBodyParts: [BodyPart] = [.biceps, .triceps, .chest, .lats, .shoulders]
        return recommendedBodyParts.shuffled().prefix(2).map { $0 }
    }

}


struct BodyPartSelectionScreen_Previews: PreviewProvider {
    static var previews: some View {
        BodyPartSelectionView(viewModel: BodyPartSelectionViewModel(appCoordinator: AppCoordinator(serviceManager: ServiceManager()), bodyPartsViewModel: MultipleChoiceCardViewModel(question: "Select the body parts you want to workout.",
            subQuestion: "You can choose multiple body parts",
            options: BodyPart.allCases.map {
            MultipleChoiceCard(title: $0.rawValue.capitalized, image: .custom(CustomIcons(rawValue: $0.rawValue) ?? .abs))
        }, isMultiselect: true), advancedBodyPartsViewModel: MultipleChoiceCardViewModel(question: "Select the body parts you want to workout.",
                                                                                         subQuestion: "You can choose multiple body parts",
                                                                                         options: BodyPart.allCases.map {
                                                                                         MultipleChoiceCard(title: $0.rawValue.capitalized, image: .custom(CustomIcons(rawValue: $0.rawValue) ?? .abs))
        }, isMultiselect: true), selectedBodyParts: [], onInitiateGenerate: {}, onGenerateWorkout: { result, bodyParts  in
            print(result)
        }))
    }
}
