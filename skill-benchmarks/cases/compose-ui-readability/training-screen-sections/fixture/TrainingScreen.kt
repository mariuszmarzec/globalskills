@Composable
fun TrainingScreen(viewModel: TrainingViewModel) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    var expandedExerciseId by rememberSaveable { mutableStateOf<String?>(null) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .padding(16.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = viewModel::onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
            }
            Column(modifier = Modifier.weight(1f)) {
                Text(text = "Training", style = MaterialTheme.typography.headlineSmall)
                Text(text = uiState.trainingName, style = MaterialTheme.typography.bodyMedium)
            }
            if (uiState.isLoading) {
                CircularProgressIndicator(modifier = Modifier.size(24.dp))
            }
        }

        Spacer(modifier = Modifier.height(20.dp))

        Card(modifier = Modifier.fillMaxWidth()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Column {
                    Text(text = "Duration", style = MaterialTheme.typography.labelMedium)
                    Text(text = uiState.durationLabel, style = MaterialTheme.typography.titleLarge)
                }
                Column {
                    Text(text = "Exercises", style = MaterialTheme.typography.labelMedium)
                    Text(text = uiState.exerciseCount.toString(), style = MaterialTheme.typography.titleLarge)
                }
                Column {
                    Text(text = "Completed", style = MaterialTheme.typography.labelMedium)
                    Text(text = uiState.completedCount.toString(), style = MaterialTheme.typography.titleLarge)
                }
            }
        }

        Spacer(modifier = Modifier.height(16.dp))
        Text(text = "Summary", style = MaterialTheme.typography.titleMedium)
        Text(text = uiState.summary, style = MaterialTheme.typography.bodyMedium)

        Spacer(modifier = Modifier.height(16.dp))
        Text(text = "Exercises", style = MaterialTheme.typography.titleMedium)
        if (uiState.exercises.isEmpty()) {
            Text(
                text = "No exercises yet",
                modifier = Modifier.padding(vertical = 24.dp),
                style = MaterialTheme.typography.bodyMedium,
            )
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                uiState.exercises.forEach { exercise ->
                    Card(modifier = Modifier.fillMaxWidth()) {
                        Column(modifier = Modifier.padding(12.dp)) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(
                                    text = exercise.name,
                                    modifier = Modifier.weight(1f),
                                    style = MaterialTheme.typography.titleMedium,
                                )
                                IconButton(
                                    onClick = {
                                        expandedExerciseId = if (expandedExerciseId == exercise.id) {
                                            null
                                        } else {
                                            exercise.id
                                        }
                                    },
                                ) {
                                    Icon(
                                        imageVector = if (expandedExerciseId == exercise.id) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                                        contentDescription = "Toggle " + exercise.name,
                                    )
                                }
                            }
                            if (expandedExerciseId == exercise.id) {
                                Text(text = exercise.description, style = MaterialTheme.typography.bodySmall)
                            }
                            Text(text = exercise.setCount.toString() + " sets · " + exercise.repetitionCount.toString() + " reps")
                        }
                    }
                }
            }
        }

        Spacer(modifier = Modifier.weight(1f))
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            OutlinedButton(
                modifier = Modifier.weight(1f),
                onClick = viewModel::onAddExercise,
            ) {
                Text(text = "Add exercise")
            }
            Button(
                modifier = Modifier.weight(1f),
                enabled = uiState.canStart,
                onClick = viewModel::onStartTraining,
            ) {
                Text(text = "Start training")
            }
        }
        if (uiState.isComplete) {
            TextButton(
                modifier = Modifier.fillMaxWidth(),
                onClick = viewModel::onComplete,
            ) {
                Text(text = "Complete")
            }
        }
    }
}
