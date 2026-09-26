import PhotosUI
import SwiftUI

// Manage everyone the wearer has profiles for, and their groups.
struct PeopleView: View {
  @Bindable var store: PeopleStore
  @Environment(\.dismiss) private var dismiss
  @State private var newPerson = ""
  @State private var newGroup = ""
  var body: some View {
    NavigationStack {
      List {
        Section("Groups") {
          ForEach(store.groups) { group in
            NavigationLink { GroupEditor(store:store, id:group.id) } label: {
              LabeledContent(group.name) { Text("\(store.members(of:group.id).count)") }
            }
          }.onDelete { $0.map { store.groups[$0].id }.forEach(store.deleteGroup) }
          AddRow(placeholder:"New group", text:$newGroup) { store.addGroup($0) }
        }
        Section("People") {
          ForEach(store.people) { person in
            NavigationLink { PersonEditor(store:store, id:person.id) } label: { PersonRow(store:store, person:person) }
          }.onDelete { store.people.remove(atOffsets:$0) }
          AddRow(placeholder:"New person", text:$newPerson) { store.addPerson($0) }
        }
      }.navigationTitle("People")
        .toolbar { Button("Done") { dismiss() } }
    }
  }
}

struct PersonRow: View {
  let store: PeopleStore
  let person: Person
  var body: some View {
    VStack(alignment:.leading, spacing:4) {
      Text(person.name)
      let labels = store.groupNames(for:person) + person.tags
      if !labels.isEmpty {
        Text(labels.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
    }
  }
}

struct AddRow: View {
  let placeholder: String
  @Binding var text: String
  let add: (String) -> Void
  var body: some View {
    HStack {
      TextField(placeholder, text:$text).onSubmit(commit)
      Button("Add", systemImage:"plus.circle.fill", action:commit).labelStyle(.iconOnly).disabled(text.trimmingCharacters(in:.whitespaces).isEmpty)
    }
  }
  private func commit() { add(text); text = "" }
}

// Editable list of short strings (notes, topics, tags, slang).
struct StringListSection: View {
  let title: String
  @Binding var items: [String]
  @State private var draft = ""
  var body: some View {
    Section(title) {
      ForEach(items.indices, id:\.self) { index in
        TextField(title, text:Binding(get: { index < items.count ? items[index] : "" },
                                      set: { if index < items.count { items[index] = $0 } }), axis:.vertical)
      }.onDelete { items.remove(atOffsets:$0) }
      AddRow(placeholder:"Add", text:$draft) { value in
        let value = value.trimmingCharacters(in:.whitespacesAndNewlines)
        if !value.isEmpty { items.append(value) }
      }
    }
  }
}

struct PersonEditor: View {
  @Bindable var store: PeopleStore
  let id: UUID
  var body: some View {
    if let index = store.people.firstIndex(where: { $0.id == id }) {
      Form {
        TextField("Name", text:$store.people[index].name).font(.title3.weight(.semibold))
        Section("Groups") {
          ForEach(store.groups) { group in
            Toggle(group.name, isOn:Binding(
              get: { store.people[index].groupIDs.contains(group.id) },
              set: { on in
                store.people[index].groupIDs.removeAll { $0 == group.id }
                if on { store.people[index].groupIDs.append(group.id) }
              }))
          }
        }
        FaceEnrollmentSection(store:store, index:index)
        StringListSection(title:"Tags", items:$store.people[index].tags)
        StringListSection(title:"Topics", items:$store.people[index].topics)
        StringListSection(title:"Notes", items:$store.people[index].notes)
      }.navigationTitle(store.people[index].name).navigationBarTitleDisplayMode(.inline)
    }
  }
}

struct GroupEditor: View {
  @Bindable var store: PeopleStore
  let id: UUID
  var body: some View {
    if let index = store.groups.firstIndex(where: { $0.id == id }) {
      Form {
        TextField("Name", text:$store.groups[index].name).font(.title3.weight(.semibold))
        Section("Members") {
          ForEach(store.people) { person in
            Toggle(person.name, isOn:Binding(
              get: { person.groupIDs.contains(id) },
              set: { on in
                guard let p = store.people.firstIndex(where: { $0.id == person.id }) else { return }
                store.people[p].groupIDs.removeAll { $0 == id }
                if on { store.people[p].groupIDs.append(id) }
              }))
          }
        }
        Section("Style") { TextField("Pace, humor, formality", text:$store.groups[index].style, axis:.vertical) }
        StringListSection(title:"Topics", items:$store.groups[index].topics)
        StringListSection(title:"Slang", items:$store.groups[index].slang)
        StringListSection(title:"Notes", items:$store.groups[index].notes)
      }.navigationTitle(store.groups[index].name).navigationBarTitleDisplayMode(.inline)
    }
  }
}

// After a conversation: approve what was learned about each person and group.
struct LearnReviewView: View {
  @Bindable var model: SessionModel
  @State var review: LearnReview
  @Environment(\.dismiss) private var dismiss
  private var targets: [LearnItem.Target] {
    var seen = Set<LearnItem.Target>()
    return review.items.map(\.target).filter { seen.insert($0).inserted }
  }
  var body: some View {
    NavigationStack {
      List {
        ForEach(targets, id:\.self) { target in
          Section(model.people.label(for:target)) {
            ForEach($review.items) { $item in
              if item.target == target {
                Toggle(isOn:$item.include) {
                  if let face = item.face, let image = UIImage(data:face.thumbnail) {
                    Label { Text(item.value) } icon: {
                      Image(uiImage:image).resizable().frame(width:44, height:44).clipShape(RoundedRectangle(cornerRadius:8))
                    }
                  } else {
                    Label(item.value, systemImage:item.icon)
                  }
                }
              }
            }
          }
        }
      }.navigationTitle("Learned").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement:.topBarLeading) { Button("Skip") { dismiss() } }
          ToolbarItem(placement:.topBarTrailing) {
            Button("Save") { model.people.apply(review.items); dismiss() }.fontWeight(.semibold)
          }
        }
    }
  }
}

struct PersonChip: View {
  let name: String
  var icon: String?
  var body: some View {
    HStack(spacing:5) {
      if let icon { Image(systemName:icon).font(.caption) }
      Text(name)
    }.font(.subheadline.weight(.semibold))
      .padding(.horizontal,12).padding(.vertical,7)
      .background(Color(red:0.78,green:0.94,blue:0.83).opacity(0.6), in:Capsule())
  }
}

extension SessionModel {
  /// How someone got into Who's here: seen (face), introduced, or only named in speech.
  func presenceIcon(for id: UUID) -> String? {
    guard let sources = presence.sources[id] else { return nil }
    if sources.contains(.face) { return "faceid" }
    return sources.contains(.introduction) ? "person.badge.plus" : "person.wave.2"
  }
}

// Who's here, updated automatically. Long-press a name to correct a wrong match.
struct PresenceChips: View {
  @Bindable var model: SessionModel
  var body: some View {
    ScrollView(.horizontal, showsIndicators:false) {
      HStack(spacing:8) {
        ForEach(model.presentPeople) { person in
          PersonChip(name:person.name, icon:model.presenceIcon(for:person.id))
            .contextMenu { Button("Not here", systemImage:"person.badge.minus", role:.destructive) { model.markNotHere(person.id) } }
        }
      }
    }
  }
}

// Live view: who's here, plus face-match distances for calibration.
struct PresenceStrip: View {
  @Bindable var model: SessionModel
  var body: some View {
    VStack(alignment:.leading, spacing:8) {
      if !model.presentPeople.isEmpty { PresenceChips(model:model) }
      if model.recognizeFaces, let readout = model.faceReadout {
        Label(readout, systemImage:"faceid").font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
    }
  }
}

// Enrolled face photos for one person, used only for on-device matching.
struct FaceEnrollmentSection: View {
  @Bindable var store: PeopleStore
  let index: Int
  @State private var selection: PhotosPickerItem?
  @State private var working = false
  @State private var error: String?
  var body: some View {
    Section {
      if !store.people[index].faces.isEmpty {
        ScrollView(.horizontal, showsIndicators:false) {
          HStack(spacing:10) {
            ForEach(store.people[index].faces) { face in
              Group {
                if let image = UIImage(data:face.thumbnail) { Image(uiImage:image).resizable() } else { Color.gray }
              }.frame(width:64, height:64).clipShape(RoundedRectangle(cornerRadius:10))
                .contextMenu {
                  Button("Remove", systemImage:"trash", role:.destructive) { store.people[index].faces.removeAll { $0.id == face.id } }
                }
            }
          }
        }
      }
      PhotosPicker(selection:$selection, matching:.images) {
        HStack {
          Label("Add face photo", systemImage:"person.crop.square.badge.camera")
          if working { Spacer(); ProgressView() }
        }
      }.disabled(working || store.people[index].faces.count >= 8)
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
    } header: { Text("Face") } footer: {
      Text("Add 3–5 clear photos from different angles and lighting. Faces are compared on this iPhone only. Long-press a photo to remove it.")
    }
    .onChange(of:selection) { _, item in
      guard let item else { return }
      selection = nil; working = true; error = nil
      Task {
        defer { working = false }
        do {
          guard let data = try await item.loadTransferable(type:Data.self), let image = UIImage(data:data) else {
            throw CopilotError(message:"Couldn't open that photo.")
          }
          let sample = try await Task.detached(priority:.userInitiated) { try FaceRecognizer.enroll(from:image) }.value
          guard index < store.people.count else { return }
          store.people[index].faces.append(sample)
        } catch { self.error = error.localizedDescription }
      }
    }
  }
}

// The setting Muse recognized, e.g. "Library" or "Funeral".
struct SceneChip: View {
  let scene: String
  var body: some View {
    Label(scene.prefix(1).uppercased() + scene.dropFirst(), systemImage:"mappin.and.ellipse")
      .font(.subheadline.weight(.semibold))
      .padding(.horizontal,12).padding(.vertical,7)
      .background(Color.orange.opacity(0.15), in:Capsule())
      .accessibilityLabel("Setting: \(scene)")
  }
}

// Shown when something the wearer said may have come across too blunt.
struct RecoveryCard: View {
  let feedback: SessionModel.ToneFeedback
  let dismiss: () -> Void
  var body: some View {
    VStack(alignment:.leading, spacing:12) {
      HStack {
        Label("SOFTEN IT", systemImage:"bubble.left.and.exclamationmark.bubble.right").font(.caption.bold()).tracking(1)
        Spacer()
        Button("Dismiss", systemImage:"xmark", action:dismiss).labelStyle(.iconOnly)
      }
      Text("“\(feedback.recovery)”").font(.system(size:23, weight:.semibold, design:.rounded))
        .frame(maxWidth:.infinity, alignment:.leading)
      if !feedback.rephrase.isEmpty {
        Label(feedback.rephrase, systemImage:"arrow.uturn.forward").font(.subheadline).opacity(0.8)
      }
    }.padding(20).foregroundStyle(.white)
      .background(feedback.strong ? Color(red:0.78, green:0.33, blue:0.12) : Color(red:0.85, green:0.52, blue:0.12), in:RoundedRectangle(cornerRadius:20))
      .accessibilityElement(children:.combine)
      .accessibilityLabel("Soften it. Say: \(feedback.recovery). Next time: \(feedback.rephrase)")
  }
}

// Teaches the app how loud the wearer's voice is, so only their own lines get a tone check.
struct ThatWasMeButton: View {
  @Bindable var model: SessionModel
  @State private var confirmed = false
  var body: some View {
    if model.captionText != nil, model.transcript.last?.levelDbFS != nil {
      Button { model.markLastLineAsMine(); confirmed = true } label: {
        Image(systemName:confirmed ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.questionmark")
      }.accessibilityLabel("That was me")
        .onChange(of:model.captionText) { _, _ in confirmed = false }
    }
  }
}
